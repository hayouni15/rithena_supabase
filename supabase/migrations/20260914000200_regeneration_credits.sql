-- Monthly regeneration credits and edit access for every unpublished creative.

alter table public.billing_plans
  add column if not exists regeneration_limit integer
  check (regeneration_limit is null or regeneration_limit >= 0);

update public.billing_plans set regeneration_limit = case code
  when 'free_trial' then 1
  when 'byok' then 10
  when 'managed' then 25
  when 'growth' then 50
  else 0 end;

alter table public.billing_plans alter column regeneration_limit set not null;

create or replace function public.consume_regeneration_credits(
  p_organization_id uuid,
  p_brand_id uuid,
  p_content_item_id uuid,
  p_quantity integer,
  p_kind text,
  p_idempotency_key text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  subscription public.subscriptions;
  credit_limit integer;
  used numeric;
begin
  if not public.is_organization_member(p_organization_id) then raise exception 'Organization unavailable' using errcode='42501'; end if;
  if p_quantity < 1 or coalesce(length(btrim(p_kind)),0)=0 or coalesce(length(btrim(p_idempotency_key)),0)=0 then raise exception 'Invalid regeneration charge' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_organization_id::text, 180019));
  select * into subscription from public.subscriptions where organization_id=p_organization_id for update;
  if subscription.id is null or subscription.status not in ('trialing','active') then raise exception 'An active subscription is required' using errcode='P0001'; end if;
  select regeneration_limit into credit_limit from public.billing_plans where code=subscription.plan_code;
  if credit_limit is null then raise exception 'Regeneration credits are unavailable for this plan' using errcode='P0001'; end if;
  select coalesce(sum(quantity),0) into used from public.usage_events
    where organization_id=p_organization_id and event_type='regeneration_credit'
      and occurred_at>=date_trunc('month',now()) and occurred_at<date_trunc('month',now())+interval '1 month';
  if exists(select 1 from public.usage_events where organization_id=p_organization_id and idempotency_key=p_idempotency_key) then
    return jsonb_build_object('limit',credit_limit,'used',used,'remaining',greatest(credit_limit-used,0));
  end if;
  if used+p_quantity > credit_limit then raise exception 'Your monthly regeneration credits have been used' using errcode='P0001'; end if;
  insert into public.usage_events(organization_id,brand_id,content_item_id,event_type,quantity,unit,provider,metadata,idempotency_key)
  values(p_organization_id,p_brand_id,p_content_item_id,'regeneration_credit',p_quantity,'credits','rithena',jsonb_build_object('kind',p_kind),p_idempotency_key)
  on conflict (organization_id,idempotency_key) where idempotency_key is not null do nothing;
  return jsonb_build_object('limit',credit_limit,'used',used+p_quantity,'remaining',credit_limit-used-p_quantity);
end;
$$;

create or replace function public.release_regeneration_credits(p_organization_id uuid,p_idempotency_key text)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not public.is_organization_member(p_organization_id) then raise exception 'Organization unavailable' using errcode='42501'; end if;
  delete from public.usage_events where organization_id=p_organization_id and event_type='regeneration_credit' and idempotency_key=p_idempotency_key;
end;
$$;

create or replace function public.prepare_unpublished_content_edit(p_content_item_id uuid,p_expected_revision integer)
returns public.content_items language plpgsql security definer set search_path='' as $$
declare item public.content_items; schedule public.schedules; job public.publish_jobs;
begin
  select * into item from public.content_items where id=p_content_item_id for update;
  if item.id is null or not public.is_organization_member(item.organization_id) then raise exception 'Content item unavailable' using errcode='42501'; end if;
  if item.content_revision<>p_expected_revision then raise exception 'Content item changed' using errcode='40001'; end if;
  if item.status in ('publishing','published','archived') then raise exception 'Published content can no longer be edited' using errcode='55000'; end if;
  if item.status='scheduled' then
    select s.* into schedule from public.schedules s where s.content_item_id=item.id and s.status='scheduled' order by s.created_at desc limit 1 for update;
    select j.* into job from public.publish_jobs j where j.schedule_id=schedule.id order by j.created_at desc limit 1 for update;
    if schedule.id is null or job.id is null or job.state not in ('queued','retrying','waiting_external') or job.provider_job_id is not null then raise exception 'Publishing has already started' using errcode='55000'; end if;
    update public.publish_jobs set state='cancelled',completed_at=now(),next_attempt_at=null,idempotency_key=idempotency_key||':cancelled:'||id::text,error_code=null,error_message=null,lease_owner=null,lease_expires_at=null where id=job.id;
    update public.schedules set status='cancelled' where id=schedule.id;
    perform set_config('rithena.lifecycle_transition','allowed',true);
    update public.content_items set status='approved',failure_code=null,failure_message=null where id=item.id returning * into item;
  end if;
  if item.status='approved' then
    perform set_config('rithena.lifecycle_transition','allowed',true);
    update public.content_items set status='ready_for_review' where id=item.id returning * into item;
  end if;
  if item.status<>'ready_for_review' then raise exception 'This creative is not ready to edit' using errcode='55000'; end if;
  return item;
end;
$$;

create or replace function public.request_unpublished_content_regeneration(
  p_content_item_id uuid,p_expected_revision integer,p_direction text,p_provider text,p_model text,p_input jsonb,p_mode text
) returns public.content_items language plpgsql security definer set search_path='' as $$
declare item public.content_items; charge integer;
begin
  item := public.prepare_unpublished_content_edit(p_content_item_id,p_expected_revision);
  charge := case when p_mode<>'media' then 0 when item.format='carousel' then 4 when item.format='image' then 1 else 0 end;
  if charge>0 then perform public.consume_regeneration_credits(item.organization_id,item.brand_id,item.id,charge,'creative',item.id||':'||(p_expected_revision+1)::text||':creative'); end if;
  return public.request_content_regeneration(p_content_item_id,p_expected_revision,p_direction,p_provider,p_model,p_input,p_mode);
end;
$$;

create or replace function public.revise_unpublished_content_copy(
  p_content_item_id uuid,p_expected_revision integer,p_platform public.social_platform,p_field text,p_value text,p_input jsonb
) returns public.content_items language plpgsql security definer set search_path='' as $$
begin
  perform public.prepare_unpublished_content_edit(p_content_item_id,p_expected_revision);
  return public.revise_content_copy(p_content_item_id,p_expected_revision,p_platform,p_field,p_value,p_input);
end;
$$;

revoke all on function public.consume_regeneration_credits(uuid,uuid,uuid,integer,text,text),public.release_regeneration_credits(uuid,text),public.prepare_unpublished_content_edit(uuid,integer),public.request_unpublished_content_regeneration(uuid,integer,text,text,text,jsonb,text),public.revise_unpublished_content_copy(uuid,integer,public.social_platform,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.consume_regeneration_credits(uuid,uuid,uuid,integer,text,text),public.prepare_unpublished_content_edit(uuid,integer),public.request_unpublished_content_regeneration(uuid,integer,text,text,text,jsonb,text),public.revise_unpublished_content_copy(uuid,integer,public.social_platform,text,text,jsonb) to authenticated;
grant execute on function public.release_regeneration_credits(uuid,text) to service_role;

create or replace function public.get_regeneration_credit_balance(p_organization_id uuid)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare credit_limit integer; used numeric;
begin
  if not public.is_organization_member(p_organization_id) then raise exception 'Organization unavailable' using errcode='42501'; end if;
  select p.regeneration_limit into credit_limit from public.subscriptions s join public.billing_plans p on p.code=s.plan_code where s.organization_id=p_organization_id;
  select coalesce(sum(quantity),0) into used from public.usage_events where organization_id=p_organization_id and event_type='regeneration_credit' and occurred_at>=date_trunc('month',now()) and occurred_at<date_trunc('month',now())+interval '1 month';
  return jsonb_build_object('limit',coalesce(credit_limit,0),'used',used,'remaining',greatest(coalesce(credit_limit,0)-used,0),'resetsAt',date_trunc('month',now())+interval '1 month');
end;
$$;
revoke all on function public.get_regeneration_credit_balance(uuid) from public,anon;
grant execute on function public.get_regeneration_credit_balance(uuid) to authenticated;
