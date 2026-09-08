-- An Edge runtime can be terminated before it records an error checkpoint.
-- Bound every production job so the UI exposes a retry instead of waiting forever.

create or replace function public.claim_next_generation_job(
  p_worker_id text, p_lease_seconds integer default 120
) returns public.generation_jobs
language plpgsql security definer set search_path = '' as $$
declare job public.generation_jobs;
begin
  if coalesce(length(btrim(p_worker_id)), 0) = 0 or p_lease_seconds not between 15 and 3600 then
    raise exception 'Invalid worker lease' using errcode = '22023';
  end if;

  update public.generation_jobs
  set state = 'failed', stage = 'timed_out', lease_owner = null, lease_expires_at = null,
      completed_at = now(), error_code = 'generation_timeout',
      error_message = 'This generation exceeded the 45-minute safety limit. Retry to continue from its last durable checkpoint.'
  where state in ('queued', 'retrying', 'running', 'waiting_external')
    and started_at <= now() - interval '45 minutes';

  update public.generation_jobs
  set state = 'retrying', lease_owner = null, lease_expires_at = null,
      next_run_at = now(), error_code = 'lease_expired',
      error_message = 'The previous worker lease expired; the stage will resume.'
  where state = 'running' and lease_expires_at <= now() and attempt < max_attempts;

  update public.generation_jobs
  set state = 'failed', lease_owner = null, lease_expires_at = null,
      completed_at = now(), error_code = 'attempts_exhausted',
      error_message = 'Generation attempts were exhausted.'
  where state = 'running' and lease_expires_at <= now() and attempt >= max_attempts;

  select * into job from public.generation_jobs
  where state in ('queued', 'retrying', 'waiting_external') and next_run_at <= now()
    and (state = 'waiting_external' or attempt < max_attempts)
  order by next_run_at, created_at
  for update skip locked limit 1;

  if job.id is null then return null; end if;
  update public.generation_jobs set state = 'running', lease_owner = p_worker_id,
    lease_expires_at = now() + make_interval(secs => p_lease_seconds),
    attempt = case when job.state = 'waiting_external' then attempt else attempt + 1 end,
    started_at = coalesce(started_at, now()), error_code = null, error_message = null
  where id = job.id returning * into job;
  return job;
end;
$$;
