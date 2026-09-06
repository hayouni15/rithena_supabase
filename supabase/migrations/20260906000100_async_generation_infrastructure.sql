-- Durable, retry-safe creative generation jobs and private media delivery.

alter table public.generation_jobs
  add column idempotency_key text,
  add column stage text not null default 'queued',
  add column progress smallint not null default 0 check (progress between 0 and 100),
  add column next_run_at timestamptz not null default now();

create unique index generation_jobs_idempotency_idx
  on public.generation_jobs (organization_id, idempotency_key)
  where idempotency_key is not null;

create index generation_jobs_ready_queue_idx
  on public.generation_jobs (next_run_at, created_at)
  where state in ('queued', 'retrying', 'waiting_external');

create table public.generation_job_stages (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  generation_job_id uuid not null,
  stage_key text not null check (btrim(stage_key) <> ''),
  state public.job_state not null,
  attempt integer not null check (attempt > 0),
  input_fingerprint text,
  output jsonb not null default '{}'::jsonb,
  error_code text,
  error_message text,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  foreign key (generation_job_id, organization_id)
    references public.generation_jobs(id, organization_id) on delete cascade,
  unique (generation_job_id, stage_key, attempt)
);

create index generation_job_stages_job_idx
  on public.generation_job_stages (generation_job_id, started_at);

alter table public.generation_job_stages enable row level security;
create policy "Organization members can view generation stages"
  on public.generation_job_stages for select to authenticated
  using ((select public.is_organization_member(organization_id)));

create or replace function public.claim_next_generation_job(
  p_worker_id text, p_lease_seconds integer default 300
) returns public.generation_jobs
language plpgsql security definer set search_path = '' as $$
declare job public.generation_jobs;
begin
  if coalesce(length(btrim(p_worker_id)), 0) = 0 or p_lease_seconds not between 15 and 3600 then
    raise exception 'Invalid worker lease' using errcode = '22023';
  end if;

  update public.generation_jobs
  set state = 'retrying', lease_owner = null, lease_expires_at = null,
      next_run_at = now(), error_code = 'lease_expired',
      error_message = 'The previous worker lease expired; the stage will resume.'
  where state in ('running', 'waiting_external') and lease_expires_at <= now()
    and attempt < max_attempts;

  update public.generation_jobs
  set state = 'failed', lease_owner = null, lease_expires_at = null,
      completed_at = now(), error_code = 'attempts_exhausted',
      error_message = 'Generation attempts were exhausted.'
  where state in ('running', 'waiting_external') and lease_expires_at <= now()
    and attempt >= max_attempts;

  select * into job from public.generation_jobs
  where state in ('queued', 'retrying') and next_run_at <= now()
    and attempt < max_attempts
  order by next_run_at, created_at
  for update skip locked limit 1;

  if job.id is null then return null; end if;
  update public.generation_jobs set state = 'running', lease_owner = p_worker_id,
    lease_expires_at = now() + make_interval(secs => p_lease_seconds),
    attempt = attempt + 1, started_at = coalesce(started_at, now()),
    error_code = null, error_message = null
  where id = job.id returning * into job;
  return job;
end;
$$;

create or replace function public.checkpoint_generation_job(
  p_job_id uuid, p_worker_id text, p_stage text, p_progress smallint,
  p_state public.job_state, p_output jsonb default '{}'::jsonb,
  p_external_job_id text default null, p_retry_after_seconds integer default null,
  p_error_code text default null, p_error_message text default null
) returns public.generation_jobs
language plpgsql security definer set search_path = '' as $$
declare job public.generation_jobs;
begin
  select * into job from public.generation_jobs where id = p_job_id for update;
  if job.id is null or job.lease_owner is distinct from p_worker_id
    or job.lease_expires_at is null or job.lease_expires_at <= now() then
    raise exception 'Generation job lease is not owned by this worker' using errcode = '42501';
  end if;
  if p_progress not between 0 and 100 or coalesce(btrim(p_stage), '') = '' then
    raise exception 'Invalid generation checkpoint' using errcode = '22023';
  end if;
  if not public.is_job_transition_allowed(job.state, p_state) and job.state <> p_state then
    raise exception 'Invalid job transition' using errcode = '22023';
  end if;

  insert into public.generation_job_stages (
    organization_id, generation_job_id, stage_key, state, attempt, output,
    error_code, error_message, completed_at
  ) values (
    job.organization_id, job.id, p_stage, p_state, job.attempt, coalesce(p_output, '{}'::jsonb),
    p_error_code, p_error_message,
    case when p_state in ('succeeded','failed','cancelled','retrying','waiting_external') then now() end
  ) on conflict (generation_job_id, stage_key, attempt) do update set
    state = excluded.state, output = excluded.output, error_code = excluded.error_code,
    error_message = excluded.error_message, completed_at = excluded.completed_at;

  update public.generation_jobs set state = p_state, stage = p_stage,
    progress = greatest(progress, p_progress), output = output || coalesce(p_output, '{}'::jsonb),
    external_job_id = coalesce(p_external_job_id, external_job_id),
    next_run_at = case when p_retry_after_seconds is null then next_run_at else now() + make_interval(secs => p_retry_after_seconds) end,
    error_code = p_error_code, error_message = p_error_message,
    completed_at = case when p_state in ('succeeded','failed','cancelled') then now() else null end,
    lease_owner = case when p_state = 'running' then lease_owner else null end,
    lease_expires_at = case when p_state = 'running' then lease_expires_at else null end
  where id = job.id returning * into job;
  return job;
end;
$$;

revoke all on function public.claim_next_generation_job(text,integer) from public, anon, authenticated;
revoke all on function public.checkpoint_generation_job(uuid,text,text,smallint,public.job_state,jsonb,text,integer,text,text) from public, anon, authenticated;
grant execute on function public.claim_next_generation_job(text,integer) to service_role;
grant execute on function public.checkpoint_generation_job(uuid,text,text,smallint,public.job_state,jsonb,text,integer,text,text) to service_role;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('creative-media', 'creative-media', false, 209715200,
  array['image/png','image/jpeg','image/webp','video/mp4','audio/mpeg','audio/wav'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create policy "Organization members can read creative media"
  on storage.objects for select to authenticated
  using (bucket_id = 'creative-media' and (select public.is_organization_member((storage.foldername(name))[1]::uuid)));

