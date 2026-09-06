-- Align unfinished jobs created by the former Vercel queue with the Veo model
-- used by the Supabase Edge worker.

update public.generation_jobs
set model = 'veo-3.1-generate-001', next_run_at = now(), updated_at = now()
where type = 'video'
  and model = 'veo-3.0-generate-001'
  and state in ('queued', 'retrying', 'waiting_external');
