-- A creative may have one active delivery schedule per destination.  Once the
-- first destination is scheduled, subsequent destinations use this path rather
-- than treating the shared content item as exclusively scheduled.
create or replace function public.schedule_additional_platform_content(
  p_content_item_id uuid,
  p_expected_revision integer,
  p_platform public.social_platform,
  p_scheduled_for timestamptz,
  p_settings jsonb default '{}'
) returns public.schedules
language plpgsql security definer set search_path = '' as $$
declare item public.content_items; variant public.platform_variants; connection public.social_connections; result public.schedules; required_scope text; settings jsonb;
begin
  if p_platform not in ('instagram','facebook','linkedin','youtube','tiktok') then
    raise exception 'Choose a supported publishing destination' using errcode = '22023';
  end if;
  if p_scheduled_for is null or p_scheduled_for < now() - interval '1 minute' or p_scheduled_for > now() + interval '1 year' then
    raise exception 'Choose a valid future publish time' using errcode = '22023';
  end if;
  if p_platform = 'tiktok' and p_settings->>'privacyLevel' not in ('PUBLIC_TO_EVERYONE','MUTUAL_FOLLOW_FRIENDS','FOLLOWER_OF_CREATOR','SELF_ONLY') then
    raise exception 'Choose an available TikTok privacy setting' using errcode = '22023';
  end if;

  select * into item from public.content_items where id = p_content_item_id for update;
  if item.id is null or not public.is_organization_member(item.organization_id) then
    raise exception 'Content item unavailable' using errcode = '42501';
  end if;
  if item.content_revision <> p_expected_revision then
    raise exception 'Content item changed' using errcode = '40001';
  end if;
  if item.status <> 'scheduled' or not (p_platform = any(item.platform_targets)) then
    raise exception 'Approve the destination version before scheduling' using errcode = '22023';
  end if;
  if not exists (select 1 from public.approvals a where a.content_item_id = item.id and a.content_revision = item.content_revision and a.decision = 'approved') then
    raise exception 'Current content revision is not approved' using errcode = '22023';
  end if;
  if p_platform in ('youtube','tiktok') and item.format <> 'short_video' then
    raise exception '% publishing requires a finished video creative', initcap(p_platform::text) using errcode = '22023';
  end if;
  if exists (
    select 1 from public.schedules s join public.platform_variants v on v.id = s.platform_variant_id
    where s.content_item_id = item.id and s.content_revision = item.content_revision
      and v.platform = p_platform and s.status = 'scheduled'
  ) then
    raise exception 'This destination is already scheduled' using errcode = '23505';
  end if;

  select * into variant from public.platform_variants
  where content_item_id = item.id and organization_id = item.organization_id and platform = p_platform and status = 'ready' for update;
  if variant.id is null or variant.selected_media_asset_id is null
    or not exists (select 1 from public.media_assets m where m.id = variant.selected_media_asset_id and m.status = 'ready')
    or not exists (select 1 from public.post_copies p where p.platform_variant_id = variant.id and p.is_selected) then
    raise exception 'The finished % media and copy are not ready', initcap(p_platform::text) using errcode = '22023';
  end if;

  required_scope := case p_platform
    when 'instagram' then 'instagram_business_content_publish'
    when 'facebook' then 'pages_manage_posts'
    when 'linkedin' then 'w_organization_social'
    when 'youtube' then 'https://www.googleapis.com/auth/youtube.upload'
    when 'tiktok' then 'video.publish'
  end;
  select * into connection from public.social_connections
  where brand_id = item.brand_id and platform = p_platform and status = 'connected'
    and required_scope = any(scopes)
    and (p_platform in ('youtube','tiktok') or token_expires_at > now())
  order by last_validated_at desc nulls last limit 1 for update;
  if connection.id is null then
    raise exception 'Connect or reconnect % before scheduling', initcap(p_platform::text) using errcode = 'P0001';
  end if;

  settings := case when p_platform = 'tiktok' then jsonb_build_object(
    'privacyLevel', p_settings->>'privacyLevel',
    'disableComment', coalesce((p_settings->>'disableComment')::boolean, false),
    'disableDuet', coalesce((p_settings->>'disableDuet')::boolean, false),
    'disableStitch', coalesce((p_settings->>'disableStitch')::boolean, false)
  ) else '{}'::jsonb end;
  insert into public.schedules(organization_id,content_item_id,platform_variant_id,social_connection_id,content_revision,scheduled_for,timezone,status,created_by)
  values(item.organization_id,item.id,variant.id,connection.id,item.content_revision,p_scheduled_for,coalesce((select timezone from public.brands where id=item.brand_id),'UTC'),'scheduled',auth.uid()) returning * into result;
  insert into public.publish_jobs(organization_id,schedule_id,content_item_id,platform_variant_id,social_connection_id,content_revision,state,idempotency_key,next_attempt_at,max_attempts,provider_payload)
  values(item.organization_id,result.id,item.id,variant.id,connection.id,item.content_revision,'queued',p_platform::text||':'||item.id::text||':revision:'||item.content_revision::text,p_scheduled_for,5,settings);
  return result;
end;
$$;

revoke all on function public.schedule_additional_platform_content(uuid,integer,public.social_platform,timestamptz,jsonb) from public, anon;
grant execute on function public.schedule_additional_platform_content(uuid,integer,public.social_platform,timestamptz,jsonb) to authenticated;
