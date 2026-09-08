-- T10/T11: a review decision can request a fresh, direction-aware rendition.
-- The new revision and its durable job are created together so a stale review
-- cannot overwrite the approved or reviewed version.

create function public.request_content_regeneration(
  p_content_item_id uuid,
  p_expected_revision integer,
  p_direction text,
  p_provider text,
  p_model text,
  p_input jsonb
) returns public.content_items
language plpgsql security definer set search_path = '' as $$
declare
  item public.content_items;
  next_revision integer;
  job_type public.generation_job_type;
begin
  select * into item from public.content_items where id = p_content_item_id for update;
  if item.id is null or not public.is_organization_member(item.organization_id) then
    raise exception 'Content item unavailable' using errcode = '42501';
  end if;
  if item.status <> 'ready_for_review' or item.content_revision <> p_expected_revision then
    raise exception 'Content item changed' using errcode = '40001';
  end if;
  if coalesce(length(btrim(p_direction)), 0) < 3 or length(p_direction) > 500 then
    raise exception 'A regeneration direction between 3 and 500 characters is required' using errcode = '22023';
  end if;
  if jsonb_typeof(p_input) <> 'object' or coalesce(length(btrim(p_provider)), 0) = 0
    or coalesce(length(btrim(p_model)), 0) = 0 then
    raise exception 'Invalid regeneration request' using errcode = '22023';
  end if;

  job_type := case when item.format = 'short_video'
    then 'video'::public.generation_job_type else 'image'::public.generation_job_type end;
  next_revision := item.content_revision + 1;

  insert into public.approvals (
    organization_id, content_item_id, content_revision, decision,
    feedback, regenerate_direction, decided_by, decided_at
  ) values (
    item.organization_id, item.id, item.content_revision, 'changes_requested',
    'Regeneration requested from shared review.', p_direction, auth.uid(), now()
  );

  perform set_config('rithena.content_revision', 'allowed', true);
  update public.content_items set content_revision = next_revision where id = item.id;
  perform set_config('rithena.lifecycle_transition', 'allowed', true);
  update public.content_items set status = 'generating' where id = item.id returning * into item;

  insert into public.generation_jobs (
    organization_id, brand_id, content_item_id, type, state, provider, model,
    idempotency_key, stage, progress, input
  ) values (
    item.organization_id, item.brand_id, item.id, job_type, 'queued', p_provider, p_model,
    item.id || ':' || next_revision::text || ':' || job_type::text || ':v1',
    'queued', 0,
    p_input || jsonb_build_object('contentRevision', next_revision, 'regenerationDirection', btrim(p_direction))
  );

  insert into public.learning_signals (
    organization_id, brand_id, content_item_id, signal_type, dimension,
    value, weight, source, created_by
  ) values (
    item.organization_id, item.brand_id, item.id, 'regenerated', 'creative_direction',
    jsonb_build_object('direction', btrim(p_direction), 'previousRevision', p_expected_revision, 'newRevision', next_revision),
    0.5, 'shared_review', auth.uid()
  );
  return item;
end;
$$;

revoke all on function public.request_content_regeneration(uuid,integer,text,text,text,jsonb) from public;
grant execute on function public.request_content_regeneration(uuid,integer,text,text,text,jsonb) to authenticated;

