-- Use the Veo preview model from the validated n8n production pipeline for
-- new or not-yet-submitted jobs. Never change a model after Vertex has issued
-- an operation ID because that same model endpoint must poll the operation.

update public.generation_jobs
set model = 'veo-3.1-generate-preview', next_run_at = now(), updated_at = now()
where type = 'video'
  and external_job_id is null
  and state in ('queued', 'retrying');
