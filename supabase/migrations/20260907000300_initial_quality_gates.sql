-- T10: persist a complete QA run and advance generated content through the
-- guarded lifecycle in one service-role-only operation.

create function public.complete_content_qa(
  p_content_item_id uuid,
  p_expected_revision integer,
  p_media_asset_id uuid,
  p_checks jsonb
) returns public.content_items
language plpgsql security definer set search_path = '' as $$
declare
  item public.content_items;
  check_row jsonb;
begin
  select * into item from public.content_items
  where id = p_content_item_id for update;

  if item.id is not null and item.status = 'ready_for_review'
    and item.content_revision = p_expected_revision and exists (
      select 1 from public.qa_checks
      where content_item_id = item.id and media_asset_id = p_media_asset_id
    ) then
    return item;
  end if;
  if item.id is null or item.status <> 'generating'
    or item.content_revision <> p_expected_revision then
    raise exception 'Content item changed before QA completed' using errcode = '40001';
  end if;
  if not exists (
    select 1 from public.media_assets
    where id = p_media_asset_id and content_item_id = item.id
      and organization_id = item.organization_id and status = 'ready'
  ) then
    raise exception 'QA media asset is unavailable' using errcode = '23503';
  end if;
  if jsonb_typeof(p_checks) <> 'array' or jsonb_array_length(p_checks) < 4 then
    raise exception 'A complete QA check set is required' using errcode = '22023';
  end if;

  delete from public.qa_checks
  where content_item_id = item.id and media_asset_id = p_media_asset_id;

  for check_row in select value from jsonb_array_elements(p_checks)
  loop
    insert into public.qa_checks (
      organization_id, content_item_id, media_asset_id, check_type,
      passed, issues, action, checker
    ) values (
      item.organization_id, item.id, p_media_asset_id,
      (check_row->>'checkType')::public.qa_check_type,
      coalesce((check_row->>'passed')::boolean, false),
      coalesce(check_row->'issues', '[]'::jsonb),
      (check_row->>'action')::public.qa_action,
      coalesce(nullif(check_row->>'checker', ''), 'rithena-rules-v1')
    );
  end loop;

  if not exists (
    select 1 from public.qa_checks
    where content_item_id = item.id and media_asset_id = p_media_asset_id
      and check_type = 'brand_accuracy'
  ) or not exists (
    select 1 from public.qa_checks
    where content_item_id = item.id and media_asset_id = p_media_asset_id
      and check_type = 'copy'
  ) or not exists (
    select 1 from public.qa_checks
    where content_item_id = item.id and media_asset_id = p_media_asset_id
      and check_type = 'policy'
  ) or not exists (
    select 1 from public.qa_checks
    where content_item_id = item.id and media_asset_id = p_media_asset_id
      and check_type = case when item.format = 'short_video'
        then 'video'::public.qa_check_type else 'visual'::public.qa_check_type end
  ) then
    raise exception 'Required QA check types are missing' using errcode = '22023';
  end if;

  perform set_config('rithena.lifecycle_transition', 'allowed', true);
  update public.content_items set status = 'qa' where id = item.id returning * into item;
  update public.content_items set status = 'ready_for_review' where id = item.id returning * into item;
  return item;
end;
$$;

revoke all on function public.complete_content_qa(uuid,integer,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.complete_content_qa(uuid,integer,uuid,jsonb) to service_role;
