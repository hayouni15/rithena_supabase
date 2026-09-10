-- T17: reuse an existing finished creative without regenerating media or copying publication state.

alter table public.content_items
  add column reused_from_content_item_id uuid;

alter table public.content_items
  add constraint content_items_reused_from_fkey
  foreign key (reused_from_content_item_id, organization_id)
  references public.content_items(id, organization_id) on delete set null (reused_from_content_item_id);

alter table public.media_assets
  drop constraint if exists media_assets_storage_bucket_storage_path_key;

create index media_assets_storage_object_idx
  on public.media_assets(storage_bucket, storage_path);

create or replace function public.reuse_content_item(
  p_content_item_id uuid,
  p_planned_for date,
  p_proposed_publish_at timestamptz
) returns uuid
language plpgsql security definer set search_path='' as $$
declare
  source public.content_items;
  target_plan public.content_plans;
  new_item_id uuid;
  source_asset public.media_assets;
  new_asset_id uuid;
  asset_map jsonb := '{}'::jsonb;
  source_variant public.platform_variants;
  new_variant_id uuid;
begin
  select * into source from public.content_items where id=p_content_item_id;
  if source.id is null or not public.is_organization_member(source.organization_id) then
    raise exception 'Content unavailable' using errcode='42501';
  end if;
  if p_planned_for is null or p_proposed_publish_at is null then
    raise exception 'Choose a valid reuse date and time.' using errcode='22023';
  end if;
  select * into target_plan from public.content_plans
  where brand_id=source.brand_id and organization_id=source.organization_id
    and status in ('draft','ready','active') and p_planned_for between starts_on and ends_on
  order by version desc limit 1;
  if target_plan.id is null then
    raise exception 'Choose a date inside one of your prepared calendar weeks.' using errcode='22023';
  end if;
  if not exists(select 1 from public.media_assets where content_item_id=source.id and status='ready')
    or not exists(select 1 from public.platform_variants where content_item_id=source.id) then
    raise exception 'This creative is not ready to reuse yet.' using errcode='22023';
  end if;

  insert into public.content_items(
    organization_id,brand_id,content_plan_id,campaign_id,content_pillar_id,planned_for,
    proposed_publish_at,platform_targets,format,archetype_key,working_title,hook,concept,
    creative_direction,call_to_action,risk_level,status,created_by,reused_from_content_item_id
  ) values (
    source.organization_id,source.brand_id,target_plan.id,source.campaign_id,source.content_pillar_id,p_planned_for,
    p_proposed_publish_at,source.platform_targets,source.format,source.archetype_key,source.working_title,source.hook,source.concept,
    source.creative_direction,source.call_to_action,source.risk_level,'ready_for_review',auth.uid(),source.id
  ) returning id into new_item_id;

  for source_asset in select * from public.media_assets where content_item_id=source.id and status='ready' order by created_at loop
    insert into public.media_assets(
      organization_id,content_item_id,asset_type,origin,status,storage_bucket,storage_path,mime_type,
      width,height,duration_seconds,file_size_bytes,checksum,provider,provider_asset_id,metadata
    ) values (
      source.organization_id,new_item_id,source_asset.asset_type,source_asset.origin,'ready',source_asset.storage_bucket,source_asset.storage_path,source_asset.mime_type,
      source_asset.width,source_asset.height,source_asset.duration_seconds,source_asset.file_size_bytes,source_asset.checksum,source_asset.provider,source_asset.provider_asset_id,
      source_asset.metadata || jsonb_build_object('reusedFromAssetId',source_asset.id)
    ) returning id into new_asset_id;
    asset_map := asset_map || jsonb_build_object(source_asset.id::text,new_asset_id::text);
  end loop;

  for source_variant in select * from public.platform_variants where content_item_id=source.id order by created_at loop
    insert into public.platform_variants(
      organization_id,content_item_id,platform,format,status,aspect_ratio,duration_seconds,platform_config,selected_media_asset_id
    ) values (
      source.organization_id,new_item_id,source_variant.platform,source_variant.format,'draft',source_variant.aspect_ratio,
      source_variant.duration_seconds,source_variant.platform_config,
      case when source_variant.selected_media_asset_id is null then null else (asset_map->>source_variant.selected_media_asset_id::text)::uuid end
    ) returning id into new_variant_id;
    insert into public.post_copies(
      organization_id,platform_variant_id,locale,headline,subhead,caption,hashtags,call_to_action,title,description,version,is_selected
    ) select source.organization_id,new_variant_id,locale,headline,subhead,caption,hashtags,call_to_action,title,description,version,is_selected
      from public.post_copies where platform_variant_id=source_variant.id;
  end loop;

  insert into public.qa_checks(
    organization_id,content_item_id,media_asset_id,content_revision,check_type,passed,score,issues,action,checker,checked_at
  ) select source.organization_id,new_item_id,
      case when q.media_asset_id is null then null else (asset_map->>q.media_asset_id::text)::uuid end,
      1,q.check_type,q.passed,q.score,q.issues,q.action,q.checker,q.checked_at
    from public.qa_checks q
    where q.content_item_id=source.id and q.content_revision=source.content_revision
      and (q.media_asset_id is null or asset_map ? q.media_asset_id::text);

  return new_item_id;
end;
$$;

revoke all on function public.reuse_content_item(uuid,date,timestamptz) from public;
grant execute on function public.reuse_content_item(uuid,date,timestamptz) to authenticated;

comment on function public.reuse_content_item(uuid,date,timestamptz) is
  'Creates a new reviewable content record using existing media and copy; schedules, approvals, jobs, and publication records are never copied.';
