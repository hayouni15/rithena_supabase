-- Resume asynchronous provider jobs after polling checkpoints and keep their
-- content lifecycle synchronized if the provider never completes.
create or replace function public.expire_stale_generation_jobs()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform set_config('rithena.lifecycle_transition', 'allowed', true);

  with expired as (
    update public.generation_jobs
    set state = 'failed',
        stage = 'timed_out',
        completed_at = now(),
        lease_owner = null,
        lease_expires_at = null,
        error_code = 'generation_timeout',
        error_message = 'This generation exceeded the 45-minute safety limit. Retry to start it again.'
    where state in ('queued', 'retrying', 'running', 'waiting_external')
      and coalesce(started_at, created_at) <= now() - interval '45 minutes'
    returning content_item_id, input
  )
  update public.content_items item
  set status = 'failed',
      failure_code = 'generation_timeout',
      failure_message = 'This generation exceeded the 45-minute safety limit. Retry to start it again.'
  from expired
  where item.id = expired.content_item_id
    and expired.input->>'contentRevision' ~ '^[0-9]+$'
    and item.content_revision = (expired.input->>'contentRevision')::integer
    and item.status in ('generating', 'qa');
end;
$$;

revoke all on function public.expire_stale_generation_jobs() from public, anon, authenticated;
grant execute on function public.expire_stale_generation_jobs() to service_role;

create or replace function public.claim_next_standard_generation_job(
  p_worker_id text,
  p_lease_seconds integer default 300
) returns public.generation_jobs
language plpgsql
security definer
set search_path = ''
as $$
declare job public.generation_jobs;
begin
  if coalesce(length(btrim(p_worker_id)), 0) = 0 or p_lease_seconds not between 15 and 3600 then
    raise exception 'Invalid worker lease' using errcode = '22023';
  end if;

  perform public.expire_stale_generation_jobs();

  update public.generation_jobs
  set state = case when attempt < max_attempts then 'retrying'::public.job_state else 'failed'::public.job_state end,
      lease_owner = null, lease_expires_at = null, next_run_at = now(),
      error_code = 'lease_expired', error_message = 'The previous worker lease expired.'
  where state = 'running' and lease_expires_at <= now()
    and coalesce(input->>'pipeline', '') not like 'product_reference_%';

  select * into job
  from public.generation_jobs
  where state in ('queued', 'retrying', 'waiting_external')
    and next_run_at <= now()
    and (state = 'waiting_external' or attempt < max_attempts)
    and coalesce(input->>'pipeline', '') not like 'product_reference_%'
  order by next_run_at, created_at
  for update skip locked
  limit 1;

  if job.id is null then return null; end if;
  update public.generation_jobs
  set state = 'running', lease_owner = p_worker_id,
      lease_expires_at = now() + make_interval(secs => p_lease_seconds),
      attempt = case when job.state = 'waiting_external' then attempt else attempt + 1 end,
      started_at = coalesce(started_at, now()), error_code = null, error_message = null
  where id = job.id
  returning * into job;
  return job;
end;
$$;

create or replace function public.claim_next_product_generation_job(
  p_worker_id text,
  p_lease_seconds integer default 300
) returns public.generation_jobs
language plpgsql
security definer
set search_path = ''
as $$
declare job public.generation_jobs;
begin
  if coalesce(length(btrim(p_worker_id)), 0) = 0 or p_lease_seconds not between 15 and 3600 then
    raise exception 'Invalid worker lease' using errcode = '22023';
  end if;

  perform public.expire_stale_generation_jobs();

  update public.generation_jobs
  set state = case when attempt < max_attempts then 'retrying'::public.job_state else 'failed'::public.job_state end,
      lease_owner = null, lease_expires_at = null, next_run_at = now(),
      error_code = 'lease_expired', error_message = 'The previous product worker lease expired.'
  where state = 'running' and lease_expires_at <= now()
    and input->>'pipeline' like 'product_reference_%';

  select * into job
  from public.generation_jobs
  where state in ('queued', 'retrying', 'waiting_external')
    and next_run_at <= now()
    and (state = 'waiting_external' or attempt < max_attempts)
    and input->>'pipeline' like 'product_reference_%'
  order by next_run_at, created_at
  for update skip locked
  limit 1;

  if job.id is null then return null; end if;
  update public.generation_jobs
  set state = 'running', lease_owner = p_worker_id,
      lease_expires_at = now() + make_interval(secs => p_lease_seconds),
      attempt = case when job.state = 'waiting_external' then attempt else attempt + 1 end,
      started_at = coalesce(started_at, now()), error_code = null, error_message = null
  where id = job.id
  returning * into job;
  return job;
end;
$$;

revoke all on function public.claim_next_standard_generation_job(text, integer), public.claim_next_product_generation_job(text, integer)
  from public, anon, authenticated;
grant execute on function public.claim_next_standard_generation_job(text, integer), public.claim_next_product_generation_job(text, integer)
  to service_role;
