-- Cancel exactly one destination while preserving any other queued destinations.
create or replace function public.cancel_platform_schedule(
  p_content_item_id uuid,
  p_expected_revision integer,
  p_platform public.social_platform
) returns public.schedules
language plpgsql security definer set search_path = '' as $$
declare item public.content_items; result public.schedules; job public.publish_jobs;
begin
  select * into item from public.content_items where id = p_content_item_id for update;
  if item.id is null or not public.is_organization_member(item.organization_id) then
    raise exception 'Content item unavailable' using errcode = '42501';
  end if;
  if item.content_revision <> p_expected_revision then
    raise exception 'Content item changed' using errcode = '40001';
  end if;
  select s.* into result from public.schedules s
  join public.platform_variants v on v.id = s.platform_variant_id
  where s.content_item_id = item.id and s.content_revision = item.content_revision
    and v.platform = p_platform and s.status = 'scheduled'
  order by s.created_at desc limit 1 for update of s;
  if result.id is null then
    raise exception 'Schedule unavailable' using errcode = '42501';
  end if;
  select * into job from public.publish_jobs where schedule_id = result.id for update;
  if job.id is null or job.state not in ('queued','retrying','waiting_external') or job.provider_job_id is not null then
    raise exception 'Publishing has already started' using errcode = '55000';
  end if;
  update public.publish_jobs set state = 'cancelled', completed_at = now(), next_attempt_at = null,
    idempotency_key = idempotency_key || ':cancelled:' || id::text,
    error_code = null, error_message = null, lease_owner = null, lease_expires_at = null
  where id = job.id;
  update public.schedules set status = 'cancelled' where id = result.id returning * into result;
  if not exists (select 1 from public.schedules where content_item_id = item.id and content_revision = item.content_revision and status = 'scheduled') then
    perform set_config('rithena.lifecycle_transition', 'allowed', true);
    update public.content_items set status = 'approved', failure_code = null, failure_message = null where id = item.id;
  end if;
  return result;
end;
$$;

revoke all on function public.cancel_platform_schedule(uuid,integer,public.social_platform) from public, anon;
grant execute on function public.cancel_platform_schedule(uuid,integer,public.social_platform) to authenticated;
