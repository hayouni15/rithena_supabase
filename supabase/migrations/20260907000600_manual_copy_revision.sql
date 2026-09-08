-- Exact manual copy edits create a new version and rules-only QA job.

create function public.revise_content_copy(
  p_content_item_id uuid, p_expected_revision integer, p_platform public.social_platform,
  p_field text, p_value text, p_input jsonb
) returns public.content_items
language plpgsql security definer set search_path = '' as $$
declare item public.content_items; variant public.platform_variants; current_copy public.post_copies; next_revision integer; source_asset_id uuid;
begin
  select * into item from public.content_items where id=p_content_item_id for update;
  if item.id is null or not public.is_organization_member(item.organization_id) then raise exception 'Content item unavailable' using errcode='42501'; end if;
  if item.status <> 'ready_for_review' or item.content_revision <> p_expected_revision then raise exception 'Content item changed' using errcode='40001'; end if;
  if p_field not in ('headline','subhead','caption','call_to_action','title') or coalesce(length(btrim(p_value)),0) < 1 or length(p_value)>5000 or jsonb_typeof(p_input)<>'object' then raise exception 'Invalid copy revision' using errcode='22023'; end if;
  select * into variant from public.platform_variants where content_item_id=item.id and platform=p_platform;
  select * into current_copy from public.post_copies where platform_variant_id=variant.id and is_selected order by version desc limit 1;
  if variant.id is null or current_copy.id is null or variant.selected_media_asset_id is null then raise exception 'Selected platform copy is unavailable' using errcode='23503'; end if;
  source_asset_id := variant.selected_media_asset_id;
  update public.post_copies set is_selected=false where platform_variant_id=variant.id and is_selected;
  insert into public.post_copies(organization_id,platform_variant_id,locale,headline,subhead,caption,hashtags,call_to_action,title,description,version,is_selected)
  values(current_copy.organization_id,current_copy.platform_variant_id,current_copy.locale,
    case when p_field='headline' then btrim(p_value) else current_copy.headline end,
    case when p_field='subhead' then btrim(p_value) else current_copy.subhead end,
    case when p_field='caption' then btrim(p_value) else current_copy.caption end,
    current_copy.hashtags,
    case when p_field='call_to_action' then btrim(p_value) else current_copy.call_to_action end,
    case when p_field='title' then btrim(p_value) else current_copy.title end,
    current_copy.description,current_copy.version+1,true);
  next_revision := item.content_revision+1;
  perform set_config('rithena.content_revision','allowed',true);
  update public.content_items set content_revision=next_revision where id=item.id;
  perform set_config('rithena.lifecycle_transition','allowed',true);
  update public.content_items set status='generating' where id=item.id returning * into item;
  insert into public.generation_jobs(organization_id,brand_id,content_item_id,type,state,provider,model,idempotency_key,stage,progress,input)
  values(item.organization_id,item.brand_id,item.id,'qa','queued','rithena','rithena-rules-v1',item.id||':'||next_revision::text||':qa:v1','queued',0,
    p_input||jsonb_build_object('contentRevision',next_revision,'editedPlatform',p_platform,'sourceMediaAssetId',source_asset_id));
  insert into public.learning_signals(organization_id,brand_id,content_item_id,signal_type,dimension,value,weight,source,created_by)
  values(item.organization_id,item.brand_id,item.id,'edited',p_field,jsonb_build_object('platform',p_platform,'revision',next_revision),1,'shared_review',auth.uid());
  return item;
end;
$$;
revoke all on function public.revise_content_copy(uuid,integer,public.social_platform,text,text,jsonb) from public;
grant execute on function public.revise_content_copy(uuid,integer,public.social_platform,text,text,jsonb) to authenticated;
