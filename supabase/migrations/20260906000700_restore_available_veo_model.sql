-- The preview alias belongs to a different Google project in the reference
-- workflow and is unavailable to Rithena's current Vertex project. Restore the
-- accessible model for operations that have not been submitted yet.

update public.generation_jobs
set model = 'veo-3.1-generate-001', next_run_at = now(), updated_at = now()
where type = 'video'
  and model = 'veo-3.1-generate-preview'
  and external_job_id is null
  and state in ('queued', 'retrying');
