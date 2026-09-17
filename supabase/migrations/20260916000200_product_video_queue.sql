-- Route both product image and product video jobs exclusively to the product worker.
create or replace function public.claim_next_standard_generation_job(p_worker_id text,p_lease_seconds integer default 300) returns public.generation_jobs
language plpgsql security definer set search_path='' as $$
declare job public.generation_jobs;
begin
  if coalesce(length(btrim(p_worker_id)),0)=0 or p_lease_seconds not between 15 and 3600 then raise exception 'Invalid worker lease' using errcode='22023';end if;
  update public.generation_jobs set state=case when attempt<max_attempts then 'retrying'::public.job_state else 'failed'::public.job_state end,lease_owner=null,lease_expires_at=null,next_run_at=now(),error_code='lease_expired',error_message='The previous worker lease expired.' where state in('running','waiting_external') and lease_expires_at<=now() and coalesce(input->>'pipeline','') not like 'product_reference_%';
  select * into job from public.generation_jobs where state in('queued','retrying') and next_run_at<=now() and attempt<max_attempts and coalesce(input->>'pipeline','') not like 'product_reference_%' order by next_run_at,created_at for update skip locked limit 1;
  if job.id is null then return null;end if;
  update public.generation_jobs set state='running',lease_owner=p_worker_id,lease_expires_at=now()+make_interval(secs=>p_lease_seconds),attempt=attempt+1,started_at=coalesce(started_at,now()),error_code=null,error_message=null where id=job.id returning * into job;return job;
end;$$;

create or replace function public.claim_next_product_generation_job(p_worker_id text,p_lease_seconds integer default 300) returns public.generation_jobs
language plpgsql security definer set search_path='' as $$
declare job public.generation_jobs;
begin
  if coalesce(length(btrim(p_worker_id)),0)=0 or p_lease_seconds not between 15 and 3600 then raise exception 'Invalid worker lease' using errcode='22023';end if;
  update public.generation_jobs set state=case when attempt<max_attempts then 'retrying'::public.job_state else 'failed'::public.job_state end,lease_owner=null,lease_expires_at=null,next_run_at=now(),error_code='lease_expired',error_message='The previous product worker lease expired.' where state in('running','waiting_external') and lease_expires_at<=now() and input->>'pipeline' like 'product_reference_%';
  select * into job from public.generation_jobs where state in('queued','retrying') and next_run_at<=now() and attempt<max_attempts and input->>'pipeline' like 'product_reference_%' order by next_run_at,created_at for update skip locked limit 1;
  if job.id is null then return null;end if;
  update public.generation_jobs set state='running',lease_owner=p_worker_id,lease_expires_at=now()+make_interval(secs=>p_lease_seconds),attempt=attempt+1,started_at=coalesce(started_at,now()),error_code=null,error_message=null where id=job.id returning * into job;return job;
end;$$;
