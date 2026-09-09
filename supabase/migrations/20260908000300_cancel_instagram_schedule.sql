-- Allow an approved Instagram post to be unscheduled before publishing begins.

create or replace function public.cancel_instagram_schedule(
  p_content_item_id uuid, p_expected_revision integer
) returns public.schedules
language plpgsql security definer set search_path='' as $$
declare
  job_id uuid; job public.publish_jobs; schedule public.schedules; item public.content_items;
begin
  select j.id into job_id from public.publish_jobs j
  where j.content_item_id=p_content_item_id
    and public.is_organization_member(j.organization_id)
  order by j.created_at desc limit 1;
  if job_id is null then raise exception 'Schedule unavailable' using errcode='42501'; end if;

  select * into job from public.publish_jobs where id=job_id for update;
  select * into schedule from public.schedules where id=job.schedule_id for update;
  select * into item from public.content_items where id=job.content_item_id for update;
  if item.content_revision<>p_expected_revision then
    raise exception 'Content item changed' using errcode='40001';
  end if;
  if item.status<>'scheduled' or schedule.status<>'scheduled'
    or job.state not in ('queued','retrying','waiting_external')
    or job.provider_job_id is not null then
    raise exception 'Publishing has already started' using errcode='55000';
  end if;

  update public.publish_jobs set state='cancelled',completed_at=now(),next_attempt_at=null,
    idempotency_key=idempotency_key||':cancelled:'||id::text,
    error_code=null,error_message=null,lease_owner=null,lease_expires_at=null where id=job.id;
  update public.schedules set status='cancelled' where id=schedule.id returning * into schedule;
  perform set_config('rithena.lifecycle_transition','allowed',true);
  update public.content_items set status='approved',failure_code=null,failure_message=null where id=item.id;
  return schedule;
end;
$$;

revoke all on function public.cancel_instagram_schedule(uuid,integer) from public,anon;
grant execute on function public.cancel_instagram_schedule(uuid,integer) to authenticated;
