-- The preview alias is listed but unavailable to this project. Move unfinished
-- jobs to the accessible stable Gemini image model without duplicating them.

update public.generation_jobs
set model = 'gemini-3.1-flash-image', next_run_at = now(), updated_at = now()
where type = 'image'
  and model = 'gemini-3.1-flash-image-preview'
  and state in ('queued', 'retrying');
