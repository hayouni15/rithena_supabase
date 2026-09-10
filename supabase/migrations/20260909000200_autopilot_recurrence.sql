-- Server-enforced autopilot controls, approval policy snapshots, and recurrence settings.

alter table public.brands
  add column autopilot_paused boolean not null default false,
  add column planning_horizon_weeks smallint not null default 1 check(planning_horizon_weeks between 1 and 4),
  add column planning_lease_owner text,
  add column planning_lease_until timestamptz,
  add constraint brands_planning_lease_pair check((planning_lease_owner is null)=(planning_lease_until is null));

alter table public.content_items
  add column content_category text not null default 'evergreen',
  add column approval_policy public.approval_policy not null default 'review';

create index brands_recurrence_idx on public.brands(autopilot_paused,status)
  where onboarding_completed_at is not null;

create or replace function public.resolve_content_category(p_archetype_key text)
returns text language sql immutable set search_path='' as $$
  select case
    when p_archetype_key='product_demo' then 'offers_and_promotions'
    when p_archetype_key='myth_fact' then 'factual_claims'
    else 'evergreen'
  end;
$$;

create or replace function public.resolve_approval_policy(
  p_brand_id uuid,p_category text,p_risk_level public.risk_level
) returns public.approval_policy
language plpgsql stable security definer set search_path='' as $$
declare b public.brands; policy public.approval_policy;
begin
  select * into b from public.brands where id=p_brand_id;
  if b.id is null or b.default_autopilot_mode='review_everything' then return 'review'; end if;
  select approval_policy into policy from public.autopilot_policies
  where brand_id=b.id and mode=b.default_autopilot_mode and content_category=p_category and is_active
  limit 1;
  if policy is distinct from 'auto' then return 'review'; end if;
  if b.default_autopilot_mode='trusted_autopilot' and p_risk_level<>'low' then return 'review'; end if;
  return 'auto';
end;
$$;

create or replace function public.apply_content_approval_policy() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  new.content_category:=public.resolve_content_category(new.archetype_key);
  new.approval_policy:=public.resolve_approval_policy(new.brand_id,new.content_category,new.risk_level);
  return new;
end;
$$;

create trigger apply_content_approval_policy_before_insert
before insert on public.content_items
for each row execute function public.apply_content_approval_policy();

create or replace function public.guard_content_approval_snapshot() returns trigger
language plpgsql set search_path='' as $$
begin
  if new.content_category is distinct from old.content_category or new.approval_policy is distinct from old.approval_policy then
    raise exception 'Content approval policy is immutable' using errcode='42501';
  end if;
  return new;
end;
$$;

create trigger guard_content_approval_snapshot_before_update
before update on public.content_items
for each row execute function public.guard_content_approval_snapshot();

create or replace function public.guard_brand_planning_lease() returns trigger
language plpgsql set search_path='' as $$
begin
  if (new.planning_lease_owner is distinct from old.planning_lease_owner or new.planning_lease_until is distinct from old.planning_lease_until)
    and auth.role()<>'service_role' then raise exception 'Planning lease is worker-managed' using errcode='42501'; end if;
  return new;
end;
$$;

create trigger guard_brand_planning_lease_before_update
before update on public.brands
for each row execute function public.guard_brand_planning_lease();

create or replace function public.auto_approve_clean_content() returns trigger
language plpgsql security definer set search_path='' as $$
declare latest_asset uuid;
begin
  if new.status<>'ready_for_review' or old.status is not distinct from new.status or new.approval_policy<>'auto' then return new; end if;
  select id into latest_asset from public.media_assets
  where content_item_id=new.id and status='ready' order by created_at desc limit 1;
  if latest_asset is null or exists(
    select 1 from public.qa_checks where content_item_id=new.id and media_asset_id=latest_asset and not passed
  ) or (select count(distinct check_type) from public.qa_checks where content_item_id=new.id and media_asset_id=latest_asset)<4 then
    return new;
  end if;
  insert into public.approvals(organization_id,content_item_id,content_revision,decision,feedback,decided_at)
  values(new.organization_id,new.id,new.content_revision,'approved','Automatically approved by the saved category policy after clean QA.',now());
  perform public.transition_content_item(new.id,'ready_for_review',new.content_revision,'approved');
  return new;
end;
$$;

create trigger auto_approve_clean_content_after_review
after update of status on public.content_items
for each row execute function public.auto_approve_clean_content();

create or replace function public.save_autopilot_settings(p_brand_id uuid,p_data jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare b public.brands; v_mode public.autopilot_mode; preset text; posts integer; horizon integer; entry jsonb;
begin
  select * into b from public.brands where id=p_brand_id for update;
  if b.id is null or not public.is_organization_member(b.organization_id) then raise exception 'Brand unavailable' using errcode='42501'; end if;
  v_mode:=(p_data->>'mode')::public.autopilot_mode;
  preset:=p_data->>'frequency';
  posts:=case preset when '3_per_week' then 3 when '5_per_week' then 5 when 'daily' then 7 when 'custom' then (p_data->>'postsPerWeek')::integer end;
  horizon:=(p_data->>'planningHorizonWeeks')::integer;
  if posts is null or posts not between 1 and 21 or horizon not between 1 and 4
    or not exists(select 1 from pg_timezone_names where name=p_data->>'timezone')
    or jsonb_typeof(p_data->'policies') is distinct from 'array' then
    raise exception 'Invalid autopilot settings' using errcode='22023';
  end if;
  update public.brands set default_autopilot_mode=v_mode,autopilot_paused=coalesce((p_data->>'paused')::boolean,false),
    timezone=p_data->>'timezone',planning_horizon_weeks=horizon where id=b.id;
  insert into public.brand_preferences(organization_id,brand_id,category,key,value,is_explicit,last_observed_at)
  values(b.organization_id,b.id,'publishing','frequency',jsonb_build_object('preset',preset,'postsPerWeek',posts),true,now())
  on conflict(brand_id,category,key) do update set value=excluded.value,is_explicit=true,last_observed_at=now();
  update public.autopilot_policies set is_active=false where brand_id=b.id;
  for entry in select value from jsonb_array_elements(p_data->'policies') loop
    if entry->>'category' not in ('evergreen','factual_claims','offers_and_promotions')
      or entry->>'approvalPolicy' not in ('auto','review') then raise exception 'Invalid category policy' using errcode='22023'; end if;
    insert into public.autopilot_policies(organization_id,brand_id,mode,content_category,risk_level,approval_policy,is_active)
    values(b.organization_id,b.id,v_mode,entry->>'category',
      case entry->>'category' when 'evergreen' then 'low'::public.risk_level when 'factual_claims' then 'medium'::public.risk_level else 'high'::public.risk_level end,
      case when v_mode='review_everything' then 'review'::public.approval_policy else (entry->>'approvalPolicy')::public.approval_policy end,true)
    on conflict(brand_id,mode,content_category) do update set approval_policy=excluded.approval_policy,risk_level=excluded.risk_level,is_active=true;
  end loop;
  if (select count(*) from public.autopilot_policies where brand_id=b.id and mode=v_mode and is_active)<>3 then
    raise exception 'Every category needs a policy' using errcode='22023';
  end if;
  return jsonb_build_object('ok',true,'paused',coalesce((p_data->>'paused')::boolean,false),'mode',v_mode,'postsPerWeek',posts,'planningHorizonWeeks',horizon);
end;
$$;

create or replace function public.create_content_review_notification() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.status='ready_for_review' and old.status is distinct from new.status and new.approval_policy='review' then
    perform public.notify_organization_members(
      new.organization_id,new.id,'approval_needed','A post is ready for review',
      coalesce(nullif(btrim(new.working_title),''),'Your generated post')||' is ready for your approval.',
      '/content/'||new.id::text,
      'approval:'||new.id::text||':revision:'||new.content_revision::text
    );
  end if;
  return new;
end;
$$;

create or replace function public.guard_paused_schedule() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.status='scheduled' and exists(
    select 1 from public.content_items i join public.brands b on b.id=i.brand_id
    where i.id=new.content_item_id and b.autopilot_paused
  ) then raise exception 'Autopilot is paused' using errcode='55000'; end if;
  return new;
end;
$$;

create trigger guard_paused_schedule_before_write
before insert or update of status,scheduled_for on public.schedules
for each row execute function public.guard_paused_schedule();

create or replace function public.prepare_weekly_content_plan(
  p_brand_id uuid,p_starts_on date,p_strategy_summary text,p_strategy_inputs jsonb,p_items jsonb
) returns uuid language plpgsql security definer set search_path='' as $$
declare b public.brands; owner_id uuid;
begin
  if auth.role()<>'service_role' then raise exception 'Service role required' using errcode='42501'; end if;
  select * into b from public.brands where id=p_brand_id;
  if b.id is null or b.autopilot_paused or b.status<>'active' then raise exception 'Brand is not eligible for recurrence' using errcode='55000'; end if;
  select user_id into owner_id from public.organization_members where organization_id=b.organization_id and role='owner' order by created_at limit 1;
  if owner_id is null then raise exception 'Brand owner unavailable' using errcode='42501'; end if;
  perform set_config('request.jwt.claim.sub',owner_id::text,true);
  return public.create_weekly_content_plan(p_brand_id,p_starts_on,p_strategy_summary,p_strategy_inputs,p_items,false);
end;
$$;

create or replace function public.claim_next_instagram_publish_job(
  p_worker_id text,p_lease_seconds integer default 120
) returns public.publish_jobs language plpgsql security definer set search_path='' as $$
declare job public.publish_jobs;
begin
  if coalesce(length(btrim(p_worker_id)),0)=0 or p_lease_seconds not between 15 and 600 then raise exception 'Invalid worker lease' using errcode='22023'; end if;
  update public.publish_jobs set state='retrying',lease_owner=null,lease_expires_at=null,next_attempt_at=now(),error_code='lease_expired',error_message='The publisher stopped before completing this attempt.'
  where state='running' and lease_expires_at<=now() and attempt<max_attempts;
  update public.publish_jobs set state='failed',lease_owner=null,lease_expires_at=null,completed_at=now(),error_code='attempts_exhausted',error_message='Publishing attempts were exhausted.'
  where state='running' and lease_expires_at<=now() and attempt>=max_attempts;
  update public.schedules s set status='failed' from public.publish_jobs j where j.schedule_id=s.id and j.state='failed' and j.error_code='attempts_exhausted' and s.status='scheduled';
  perform set_config('rithena.lifecycle_transition','allowed',true);
  update public.content_items c set status='failed',failure_code='attempts_exhausted',failure_message='Publishing attempts were exhausted.' from public.publish_jobs j
  where j.content_item_id=c.id and j.content_revision=c.content_revision and j.state='failed' and j.error_code='attempts_exhausted' and c.status='publishing';
  select j.* into job from public.publish_jobs j
  join public.schedules s on s.id=j.schedule_id join public.content_items i on i.id=j.content_item_id join public.brands b on b.id=i.brand_id
  where j.state in ('queued','retrying','waiting_external') and coalesce(j.next_attempt_at,s.scheduled_for)<=now()
    and (j.state='waiting_external' or j.attempt<j.max_attempts) and s.status='scheduled' and not b.autopilot_paused
  order by coalesce(j.next_attempt_at,s.scheduled_for),j.created_at for update of j skip locked limit 1;
  if job.id is null then return null; end if;
  update public.publish_jobs set state='running',lease_owner=p_worker_id,lease_expires_at=now()+make_interval(secs=>p_lease_seconds),
    attempt=case when job.state='waiting_external' then attempt else attempt+1 end,started_at=coalesce(started_at,now()),error_code=null,error_message=null
  where id=job.id returning * into job;
  perform set_config('rithena.lifecycle_transition','allowed',true);
  update public.content_items set status='publishing' where id=job.content_item_id and status='scheduled' and content_revision=job.content_revision;
  return job;
end;
$$;

revoke all on function public.resolve_content_category(text) from public,anon;
revoke all on function public.resolve_approval_policy(uuid,text,public.risk_level) from public,anon;
revoke all on function public.save_autopilot_settings(uuid,jsonb) from public,anon;
grant execute on function public.save_autopilot_settings(uuid,jsonb) to authenticated;
revoke all on function public.prepare_weekly_content_plan(uuid,date,text,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.prepare_weekly_content_plan(uuid,date,text,jsonb,jsonb) to service_role;
revoke all on function public.apply_content_approval_policy() from public,anon,authenticated;
revoke all on function public.guard_content_approval_snapshot() from public,anon,authenticated;
revoke all on function public.guard_brand_planning_lease() from public,anon,authenticated;
revoke all on function public.auto_approve_clean_content() from public,anon,authenticated;
revoke all on function public.guard_paused_schedule() from public,anon,authenticated;
