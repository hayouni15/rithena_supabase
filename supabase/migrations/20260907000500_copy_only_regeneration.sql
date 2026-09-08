-- Preserve QA history by content revision and add a low-cost copy-only route.

alter table public.qa_checks add column content_revision integer;
update public.qa_checks q set content_revision = c.content_revision
from public.content_items c where c.id = q.content_item_id and q.content_revision is null;
alter table public.qa_checks alter column content_revision set not null,
  add constraint qa_checks_content_revision_positive check (content_revision > 0);
create index qa_checks_content_revision_idx on public.qa_checks(content_item_id, content_revision, checked_at desc);

create or replace function public.complete_content_qa(
  p_content_item_id uuid, p_expected_revision integer, p_media_asset_id uuid, p_checks jsonb
) returns public.content_items
language plpgsql security definer set search_path = '' as $$
declare item public.content_items; check_row jsonb;
begin
  select * into item from public.content_items where id = p_content_item_id for update;
  if item.id is not null and item.status = 'ready_for_review' and item.content_revision = p_expected_revision
    and exists (select 1 from public.qa_checks where content_item_id = item.id and media_asset_id = p_media_asset_id and content_revision = p_expected_revision) then return item; end if;
  if item.id is null or item.status <> 'generating' or item.content_revision <> p_expected_revision then raise exception 'Content item changed before QA completed' using errcode = '40001'; end if;
  if not exists (select 1 from public.media_assets where id = p_media_asset_id and content_item_id = item.id and organization_id = item.organization_id and status = 'ready') then raise exception 'QA media asset is unavailable' using errcode = '23503'; end if;
  if jsonb_typeof(p_checks) <> 'array' or jsonb_array_length(p_checks) < 4 then raise exception 'A complete QA check set is required' using errcode = '22023'; end if;
  delete from public.qa_checks where content_item_id = item.id and media_asset_id = p_media_asset_id and content_revision = p_expected_revision;
  for check_row in select value from jsonb_array_elements(p_checks) loop
    insert into public.qa_checks (organization_id, content_item_id, media_asset_id, content_revision, check_type, passed, issues, action, checker)
    values (item.organization_id, item.id, p_media_asset_id, item.content_revision, (check_row->>'checkType')::public.qa_check_type,
      coalesce((check_row->>'passed')::boolean, false), coalesce(check_row->'issues', '[]'::jsonb),
      (check_row->>'action')::public.qa_action, coalesce(nullif(check_row->>'checker', ''), 'rithena-rules-v1'));
  end loop;
  if not exists (select 1 from public.qa_checks where content_item_id = item.id and media_asset_id = p_media_asset_id and content_revision = item.content_revision and check_type = 'brand_accuracy')
    or not exists (select 1 from public.qa_checks where content_item_id = item.id and media_asset_id = p_media_asset_id and content_revision = item.content_revision and check_type = 'copy')
    or not exists (select 1 from public.qa_checks where content_item_id = item.id and media_asset_id = p_media_asset_id and content_revision = item.content_revision and check_type = 'policy')
    or not exists (select 1 from public.qa_checks where content_item_id = item.id and media_asset_id = p_media_asset_id and content_revision = item.content_revision and check_type = case when item.format = 'short_video' then 'video'::public.qa_check_type else 'visual'::public.qa_check_type end) then raise exception 'Required QA check types are missing' using errcode = '22023'; end if;
  perform set_config('rithena.lifecycle_transition', 'allowed', true);
  update public.content_items set status = 'qa' where id = item.id returning * into item;
  update public.content_items set status = 'ready_for_review' where id = item.id returning * into item;
  return item;
end;
$$;

create or replace function public.request_content_regeneration(
  p_content_item_id uuid, p_expected_revision integer, p_direction text,
  p_provider text, p_model text, p_input jsonb, p_mode text
) returns public.content_items
language plpgsql security definer set search_path = '' as $$
declare item public.content_items; next_revision integer; job_type public.generation_job_type; source_asset_id uuid;
begin
  select * into item from public.content_items where id = p_content_item_id for update;
  if item.id is null or not public.is_organization_member(item.organization_id) then raise exception 'Content item unavailable' using errcode = '42501'; end if;
  if item.status <> 'ready_for_review' or item.content_revision <> p_expected_revision then raise exception 'Content item changed' using errcode = '40001'; end if;
  if coalesce(length(btrim(p_direction)), 0) < 3 or length(p_direction) > 500 then raise exception 'A regeneration direction between 3 and 500 characters is required' using errcode = '22023'; end if;
  if jsonb_typeof(p_input) <> 'object' or coalesce(length(btrim(p_provider)), 0) = 0 or coalesce(length(btrim(p_model)), 0) = 0 or p_mode not in ('copy', 'media') then raise exception 'Invalid regeneration request' using errcode = '22023'; end if;
  if p_mode = 'media'
    and exists (select 1 from public.qa_checks where content_item_id = item.id and content_revision = item.content_revision and not passed and check_type in ('brand_accuracy', 'copy', 'policy'))
    and not exists (select 1 from public.qa_checks where content_item_id = item.id and content_revision = item.content_revision and not passed and check_type in ('visual', 'video')) then
    raise exception 'This QA concern requires a copy-only revision; no new media is needed' using errcode = '22023';
  end if;
  if p_mode = 'copy' then
    select id into source_asset_id from public.media_assets where content_item_id = item.id and organization_id = item.organization_id and status = 'ready' order by created_at desc limit 1;
    if source_asset_id is null then raise exception 'A finished media asset is required for a copy-only revision' using errcode = '23503'; end if;
    job_type := 'copy'::public.generation_job_type;
  else
    job_type := case when item.format = 'short_video' then 'video'::public.generation_job_type else 'image'::public.generation_job_type end;
  end if;
  next_revision := item.content_revision + 1;
  insert into public.approvals (organization_id, content_item_id, content_revision, decision, feedback, regenerate_direction, decided_by, decided_at)
  values (item.organization_id, item.id, item.content_revision, 'changes_requested', case when p_mode = 'copy' then 'Copy-only revision requested from shared review.' else 'Media regeneration requested from shared review.' end, p_direction, auth.uid(), now());
  perform set_config('rithena.content_revision', 'allowed', true);
  update public.content_items set content_revision = next_revision where id = item.id;
  perform set_config('rithena.lifecycle_transition', 'allowed', true);
  update public.content_items set status = 'generating' where id = item.id returning * into item;
  insert into public.generation_jobs (organization_id, brand_id, content_item_id, type, state, provider, model, idempotency_key, stage, progress, input)
  values (item.organization_id, item.brand_id, item.id, job_type, 'queued', p_provider, p_model,
    item.id || ':' || next_revision::text || ':' || job_type::text || ':v1', 'queued', 0,
    p_input || jsonb_build_object('contentRevision', next_revision, 'regenerationDirection', btrim(p_direction), 'regenerationMode', p_mode, 'sourceMediaAssetId', source_asset_id));
  insert into public.learning_signals (organization_id, brand_id, content_item_id, signal_type, dimension, value, weight, source, created_by)
  values (item.organization_id, item.brand_id, item.id, 'regenerated', case when p_mode = 'copy' then 'copy' else 'creative_direction' end,
    jsonb_build_object('direction', btrim(p_direction), 'mode', p_mode, 'previousRevision', p_expected_revision, 'newRevision', next_revision), 0.5, 'shared_review', auth.uid());
  return item;
end;
$$;

revoke all on function public.request_content_regeneration(uuid,integer,text,text,text,jsonb,text) from public;
grant execute on function public.request_content_regeneration(uuid,integer,text,text,text,jsonb,text) to authenticated;
revoke execute on function public.request_content_regeneration(uuid,integer,text,text,text,jsonb) from authenticated;
