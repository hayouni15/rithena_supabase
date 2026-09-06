-- Explicit content state transitions, version-bound approvals, and leased job ownership.

alter table public.content_items
  add column content_revision integer not null default 1 check (content_revision > 0);

alter table public.approvals
  add column content_revision integer;

update public.approvals a
set content_revision = c.content_revision
from public.content_items c
where c.id = a.content_item_id and a.content_revision is null;

alter table public.approvals
  alter column content_revision set not null,
  add constraint approvals_content_revision_positive check (content_revision > 0);

alter table public.generation_jobs
  add column lease_owner text,
  add column lease_expires_at timestamptz,
  add constraint generation_jobs_lease_pair check (
    (lease_owner is null and lease_expires_at is null)
    or (lease_owner is not null and btrim(lease_owner) <> '' and lease_expires_at is not null)
  );

create function public.is_content_transition_allowed(
  p_from public.content_item_status,
  p_to public.content_item_status
) returns boolean
language sql immutable set search_path = '' as $$
  select case p_from
    when 'draft_plan' then p_to in ('planned', 'skipped', 'archived')
    when 'planned' then p_to in ('generating', 'skipped', 'archived')
    when 'generating' then p_to in ('qa', 'failed')
    when 'qa' then p_to in ('ready_for_review', 'generating', 'failed')
    when 'ready_for_review' then p_to in ('approved', 'generating', 'skipped')
    when 'approved' then p_to in ('scheduled', 'ready_for_review', 'skipped')
    when 'scheduled' then p_to in ('publishing', 'approved', 'failed')
    when 'publishing' then p_to in ('published', 'failed')
    when 'failed' then p_to in ('planned', 'generating', 'scheduled', 'archived')
    when 'skipped' then p_to in ('planned', 'archived')
    when 'published' then p_to = 'archived'
    else false
  end;
$$;

create function public.guard_content_item_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.status is distinct from old.status then
    if coalesce(current_setting('rithena.lifecycle_transition', true), '') <> 'allowed' then
      raise exception 'Use transition_content_item to change status' using errcode = '42501';
    end if;
    if not public.is_content_transition_allowed(old.status, new.status) then
      raise exception 'Invalid content transition: % -> %', old.status, new.status using errcode = '22023';
    end if;
  end if;

  if row(
    new.brand_id, new.content_plan_id, new.campaign_id, new.content_pillar_id,
    new.planned_for, new.platform_targets, new.format, new.archetype_key,
    new.working_title, new.hook, new.concept, new.creative_direction,
    new.call_to_action, new.risk_level
  ) is distinct from row(
    old.brand_id, old.content_plan_id, old.campaign_id, old.content_pillar_id,
    old.planned_for, old.platform_targets, old.format, old.archetype_key,
    old.working_title, old.hook, old.concept, old.creative_direction,
    old.call_to_action, old.risk_level
  ) then
    new.content_revision := old.content_revision + 1;
  elsif new.content_revision <> old.content_revision
    and coalesce(current_setting('rithena.content_revision', true), '') <> 'allowed' then
    raise exception 'Content revision is managed by Rithena' using errcode = '42501';
  end if;
  return new;
end;
$$;

create function public.guard_content_item_insert() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.status <> 'draft_plan' then
    raise exception 'New content items must begin as draft plans' using errcode = '22023';
  end if;
  return new;
end;
$$;

create trigger guard_content_item_insert
before insert on public.content_items
for each row execute function public.guard_content_item_insert();

create trigger guard_content_item_update
before update on public.content_items
for each row execute function public.guard_content_item_update();

create function public.transition_content_item(
  p_content_item_id uuid,
  p_expected_status public.content_item_status,
  p_expected_revision integer,
  p_next_status public.content_item_status,
  p_failure_code text default null,
  p_failure_message text default null
) returns public.content_items
language plpgsql security definer set search_path = '' as $$
declare item public.content_items;
begin
  select * into item from public.content_items where id = p_content_item_id for update;
  if item.id is null or not public.is_organization_member(item.organization_id) then
    raise exception 'Content item unavailable' using errcode = '42501';
  end if;
  if item.status <> p_expected_status or item.content_revision <> p_expected_revision then
    raise exception 'Content item changed' using errcode = '40001';
  end if;
  if not public.is_content_transition_allowed(item.status, p_next_status) then
    raise exception 'Invalid content transition: % -> %', item.status, p_next_status using errcode = '22023';
  end if;
  if p_next_status in ('approved', 'scheduled') and not exists (
    select 1 from public.approvals a
    where a.content_item_id = item.id
      and a.content_revision = item.content_revision
      and a.decision = 'approved'
  ) then
    raise exception 'Current content revision is not approved' using errcode = '22023';
  end if;
  perform set_config('rithena.lifecycle_transition', 'allowed', true);
  update public.content_items
  set status = p_next_status,
      failure_code = case when p_next_status = 'failed' then p_failure_code else null end,
      failure_message = case when p_next_status = 'failed' then p_failure_message else null end
  where id = item.id
  returning * into item;
  return item;
end;
$$;

create function public.bump_content_revision(
  p_content_item_id uuid,
  p_expected_revision integer
) returns integer
language plpgsql security definer set search_path = '' as $$
declare item public.content_items;
begin
  select * into item from public.content_items where id = p_content_item_id for update;
  if item.id is null or not public.is_organization_member(item.organization_id) then
    raise exception 'Content item unavailable' using errcode = '42501';
  end if;
  if item.content_revision <> p_expected_revision then
    raise exception 'Content item changed' using errcode = '40001';
  end if;
  perform set_config('rithena.content_revision', 'allowed', true);
  update public.content_items set content_revision = content_revision + 1 where id = item.id
  returning content_revision into p_expected_revision;
  return p_expected_revision;
end;
$$;

create function public.decide_content_item(
  p_content_item_id uuid,
  p_expected_revision integer,
  p_decision public.approval_decision,
  p_creative_variant_id uuid default null,
  p_feedback text default null,
  p_regenerate_direction text default null
) returns public.approvals
language plpgsql security definer set search_path = '' as $$
declare item public.content_items; result public.approvals;
begin
  select * into item from public.content_items where id = p_content_item_id for update;
  if item.id is null or not public.is_organization_member(item.organization_id) then
    raise exception 'Content item unavailable' using errcode = '42501';
  end if;
  if item.content_revision <> p_expected_revision then
    raise exception 'Content item changed' using errcode = '40001';
  end if;
  if item.status <> 'ready_for_review' or p_decision not in ('approved', 'rejected', 'changes_requested', 'skipped') then
    raise exception 'Content item is not ready for this decision' using errcode = '22023';
  end if;
  if p_creative_variant_id is not null and not exists (
    select 1 from public.creative_variants v
    where v.id = p_creative_variant_id and v.content_item_id = item.id
      and v.organization_id = item.organization_id
  ) then
    raise exception 'Creative variant unavailable' using errcode = '42501';
  end if;
  insert into public.approvals(
    organization_id, content_item_id, creative_variant_id, content_revision,
    decision, feedback, regenerate_direction, decided_by, decided_at
  ) values (
    item.organization_id, item.id, p_creative_variant_id, item.content_revision,
    p_decision, p_feedback, p_regenerate_direction, auth.uid(), now()
  ) returning * into result;
  if p_decision = 'approved' then
    perform public.transition_content_item(item.id, item.status, item.content_revision, 'approved');
  elsif p_decision = 'skipped' then
    perform public.transition_content_item(item.id, item.status, item.content_revision, 'skipped');
  end if;
  return result;
end;
$$;

create function public.guard_schedule() returns trigger
language plpgsql set search_path = '' as $$
declare item public.content_items; variant public.platform_variants;
begin
  select * into item from public.content_items where id = new.content_item_id;
  select * into variant from public.platform_variants where id = new.platform_variant_id;
  if item.id is null or variant.id is null
    or item.organization_id <> new.organization_id
    or variant.organization_id <> new.organization_id
    or variant.content_item_id <> item.id then
    raise exception 'Schedule resources do not belong to the same content item' using errcode = '23503';
  end if;
  if new.status = 'scheduled' and (
    item.status not in ('approved', 'scheduled')
    or not exists (
      select 1 from public.approvals a where a.content_item_id = item.id
        and a.content_revision = item.content_revision and a.decision = 'approved'
    )
  ) then
    raise exception 'Current content revision is not approved' using errcode = '22023';
  end if;
  return new;
end;
$$;

create trigger guard_schedule before insert or update on public.schedules
for each row execute function public.guard_schedule();

create function public.is_job_transition_allowed(p_from public.job_state, p_to public.job_state)
returns boolean language sql immutable set search_path = '' as $$
  select case p_from
    when 'queued' then p_to in ('running', 'cancelled')
    when 'running' then p_to in ('waiting_external', 'retrying', 'succeeded', 'failed', 'cancelled')
    when 'waiting_external' then p_to in ('running', 'retrying', 'succeeded', 'failed', 'cancelled')
    when 'retrying' then p_to in ('running', 'failed', 'cancelled')
    else false
  end;
$$;

create function public.claim_generation_job(p_job_id uuid, p_worker_id text, p_lease_seconds integer default 300)
returns public.generation_jobs language plpgsql security definer set search_path = '' as $$
declare job public.generation_jobs;
begin
  if coalesce(length(btrim(p_worker_id)), 0) = 0 or p_lease_seconds not between 15 and 3600 then
    raise exception 'Invalid worker lease' using errcode = '22023';
  end if;
  select * into job from public.generation_jobs where id = p_job_id for update;
  if job.id is null then raise exception 'Generation job unavailable' using errcode = '42501'; end if;
  if job.state not in ('queued', 'retrying')
    or (job.lease_expires_at is not null and job.lease_expires_at > now()) then
    raise exception 'Generation job cannot be claimed' using errcode = '55000';
  end if;
  update public.generation_jobs set state = 'running', lease_owner = p_worker_id,
    lease_expires_at = now() + make_interval(secs => p_lease_seconds),
    attempt = attempt + 1, started_at = coalesce(started_at, now())
  where id = job.id returning * into job;
  return job;
end;
$$;

create function public.transition_generation_job(
  p_job_id uuid, p_worker_id text, p_expected_state public.job_state,
  p_next_state public.job_state, p_output jsonb default null,
  p_error_code text default null, p_error_message text default null
) returns public.generation_jobs language plpgsql security definer set search_path = '' as $$
declare job public.generation_jobs;
begin
  select * into job from public.generation_jobs where id = p_job_id for update;
  if job.id is null or job.lease_owner is distinct from p_worker_id
    or job.lease_expires_at is null or job.lease_expires_at <= now() then
    raise exception 'Generation job lease is not owned by this worker' using errcode = '42501';
  end if;
  if job.state <> p_expected_state then raise exception 'Generation job changed' using errcode = '40001'; end if;
  if not public.is_job_transition_allowed(job.state, p_next_state) then
    raise exception 'Invalid job transition: % -> %', job.state, p_next_state using errcode = '22023';
  end if;
  update public.generation_jobs set state = p_next_state,
    output = coalesce(p_output, output), error_code = p_error_code, error_message = p_error_message,
    completed_at = case when p_next_state in ('succeeded', 'failed', 'cancelled') then now() else null end,
    lease_owner = case when p_next_state in ('running', 'waiting_external') then lease_owner else null end,
    lease_expires_at = case when p_next_state in ('running', 'waiting_external') then lease_expires_at else null end
  where id = job.id returning * into job;
  return job;
end;
$$;

revoke insert, update, delete on public.approvals from authenticated;
revoke update on public.content_items from authenticated;
grant update (
  content_plan_id, campaign_id, content_pillar_id, planned_for, platform_targets,
  format, archetype_key, working_title, hook, concept, creative_direction,
  call_to_action, risk_level
) on public.content_items to authenticated;

revoke all on function public.transition_content_item(uuid,public.content_item_status,integer,public.content_item_status,text,text) from public;
revoke all on function public.bump_content_revision(uuid,integer) from public;
revoke all on function public.decide_content_item(uuid,integer,public.approval_decision,uuid,text,text) from public;
grant execute on function public.transition_content_item(uuid,public.content_item_status,integer,public.content_item_status,text,text) to authenticated;
grant execute on function public.bump_content_revision(uuid,integer) to authenticated;
grant execute on function public.decide_content_item(uuid,integer,public.approval_decision,uuid,text,text) to authenticated;

revoke all on function public.claim_generation_job(uuid,text,integer) from public, anon, authenticated;
revoke all on function public.transition_generation_job(uuid,text,public.job_state,public.job_state,jsonb,text,text) from public, anon, authenticated;
grant execute on function public.claim_generation_job(uuid,text,integer) to service_role;
grant execute on function public.transition_generation_job(uuid,text,public.job_state,public.job_state,jsonb,text,text) to service_role;
