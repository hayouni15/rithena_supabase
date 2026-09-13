-- C3: recipe-owned image strategy and immutable design-regeneration lineage.

update public.creative_recipes set is_active = false
where key = 'foundation-image' and version = 1;

insert into public.creative_recipes(key,version,name,status,schema_version,manifest,is_active)
values
(
  'editorial-provocation', 1, 'Editorial Provocation', 'experimental', 2,
  '{
    "schemaVersion":2,"id":"editorial-provocation","version":1,"name":"Editorial Provocation","status":"experimental",
    "formats":["image"],"goals":["build_authority","grow_audience","stay_visible"],"industries":["all"],
    "platforms":["instagram","facebook","linkedin","tiktok","youtube"],"textStrategy":"ai_native",
    "fieldOwnership":[
      {"field":"headline","precision":"expressive","renderer":"model"},{"field":"subhead","precision":"expressive","renderer":"model"},
      {"field":"cta","precision":"exact","renderer":"rithena"},{"field":"logo","precision":"exact","renderer":"rithena"}
    ],
    "narrative":{"hookFamilies":["contrarian","provocation","manifesto"],"requiredContent":["headline","cta"]},
    "visual":{"artDirection":"Typography is part of the visual idea: editorial, asymmetric, bold, and unmistakably art-directed.","compositionFamily":"editorial-provocation","subjectPlacement":"adaptive","textDensity":"low"},
    "slots":[{"id":"artwork","kind":"source_image","required":true},{"id":"cta","kind":"text","required":true},{"id":"logo","kind":"logo","required":false}],
    "variants":[{"id":"asymmetric-editorial","label":"Asymmetric editorial","overrides":{"preserve":["subject","palette","typographic_character"]}}],
    "qualityRules":["text_fidelity","no_extra_text","logo_integrity","safe_zones","creative_coherence"]
  }'::jsonb, true
),
(
  'product-hero', 1, 'Product Hero', 'experimental', 2,
  '{
    "schemaVersion":2,"id":"product-hero","version":1,"name":"Product Hero","status":"experimental",
    "formats":["image"],"goals":["promote_products","get_leads","stay_visible"],"industries":["all"],
    "platforms":["instagram","facebook","linkedin","tiktok","youtube"],"textStrategy":"hybrid",
    "fieldOwnership":[
      {"field":"headline","precision":"expressive","renderer":"model"},{"field":"subhead","precision":"expressive","renderer":"model"},
      {"field":"cta","precision":"exact","renderer":"rithena"},{"field":"logo","precision":"exact","renderer":"rithena"}
    ],
    "narrative":{"hookFamilies":["direct_benefit","desire","product_truth"],"requiredContent":["headline","cta"]},
    "visual":{"artDirection":"Premium product-led scene with integrated expressive headline and restrained exact conversion overlays.","compositionFamily":"product-hero","subjectPlacement":"center","textDensity":"low"},
    "slots":[{"id":"artwork","kind":"source_image","required":true},{"id":"cta","kind":"text","required":true},{"id":"logo","kind":"logo","required":false}],
    "variants":[{"id":"cinematic-product","label":"Cinematic product","overrides":{"preserve":["product","palette","lighting","camera_angle"]}}],
    "qualityRules":["text_fidelity","no_extra_text","logo_integrity","product_grounding","safe_zones"]
  }'::jsonb, true
),
(
  'three-key-facts', 1, 'Three Key Facts', 'experimental', 2,
  '{
    "schemaVersion":2,"id":"three-key-facts","version":1,"name":"Three Key Facts","status":"experimental",
    "formats":["image","carousel"],"goals":["educate","build_authority","get_leads"],"industries":["all"],
    "platforms":["instagram","facebook","linkedin","tiktok","youtube"],"textStrategy":"structured_overlay",
    "fieldOwnership":[
      {"field":"headline","precision":"exact","renderer":"rithena"},{"field":"subhead","precision":"exact","renderer":"rithena"},
      {"field":"cta","precision":"exact","renderer":"rithena"},{"field":"logo","precision":"exact","renderer":"rithena"}
    ],
    "narrative":{"hookFamilies":["useful_facts","how_to","comparison"],"requiredContent":["headline","subhead","cta"]},
    "visual":{"artDirection":"Clean supporting visual with controlled negative space for exact factual hierarchy.","compositionFamily":"structured-facts","subjectPlacement":"adaptive","textDensity":"medium"},
    "slots":[{"id":"plate","kind":"source_image","required":true},{"id":"contrast","kind":"treatment","required":true},{"id":"title","kind":"text","required":true},{"id":"subtitle","kind":"text","required":true},{"id":"cta","kind":"text","required":true},{"id":"logo","kind":"logo","required":false}],
    "variants":[{"id":"fact-stack","label":"Fact stack","overrides":{"layout":"left_stacked"}},{"id":"bottom-summary","label":"Bottom summary","overrides":{"layout":"bottom_minimal"}}],
    "qualityRules":["exact_text","safe_zones","text_contrast","logo_integrity","claim_grounding"]
  }'::jsonb, true
)
on conflict(key,version) do update set
  name=excluded.name,status=excluded.status,schema_version=excluded.schema_version,
  manifest=excluded.manifest,is_active=excluded.is_active;

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
  if jsonb_typeof(p_input) <> 'object' or coalesce(length(btrim(p_provider)), 0) = 0 or coalesce(length(btrim(p_model)), 0) = 0 or p_mode not in ('copy','media','update_design','reimagine') then raise exception 'Invalid regeneration request' using errcode = '22023'; end if;
  if p_mode in ('update_design','reimagine') and item.format <> 'image' then raise exception 'Design regeneration is available only for images' using errcode = '22023'; end if;
  if p_mode = 'media'
    and exists (select 1 from public.qa_checks where content_item_id = item.id and content_revision = item.content_revision and not passed and check_type in ('brand_accuracy','copy','policy'))
    and not exists (select 1 from public.qa_checks where content_item_id = item.id and content_revision = item.content_revision and not passed and check_type in ('visual','video')) then
    raise exception 'This QA concern requires a copy-only revision; no new media is needed' using errcode = '22023';
  end if;
  if p_mode in ('copy','update_design','reimagine') then
    select pv.selected_media_asset_id into source_asset_id
      from public.platform_variants pv
      where pv.content_item_id = item.id and pv.organization_id = item.organization_id and pv.selected_media_asset_id is not null
      order by pv.updated_at desc limit 1;
    if source_asset_id is null then
      select id into source_asset_id from public.media_assets
        where content_item_id = item.id and organization_id = item.organization_id and status = 'ready'
        order by created_at desc limit 1;
    end if;
    if source_asset_id is null then raise exception 'A finished media asset is required for this revision' using errcode = '23503'; end if;
  end if;
  job_type := case when p_mode = 'copy' then 'copy'::public.generation_job_type when item.format = 'short_video' then 'video'::public.generation_job_type else 'image'::public.generation_job_type end;
  next_revision := item.content_revision + 1;
  insert into public.approvals (organization_id,content_item_id,content_revision,decision,feedback,regenerate_direction,decided_by,decided_at)
  values (item.organization_id,item.id,item.content_revision,'changes_requested',case when p_mode='copy' then 'Copy-only revision requested from shared review.' when p_mode='update_design' then 'Update-design revision requested from shared review.' when p_mode='reimagine' then 'Reimagined revision requested from shared review.' else 'Media regeneration requested from shared review.' end,p_direction,auth.uid(),now());
  perform set_config('rithena.content_revision','allowed',true);
  update public.content_items set content_revision=next_revision where id=item.id;
  perform set_config('rithena.lifecycle_transition','allowed',true);
  update public.content_items set status='generating' where id=item.id returning * into item;
  insert into public.generation_jobs (organization_id,brand_id,content_item_id,type,state,provider,model,idempotency_key,stage,progress,input)
  values (item.organization_id,item.brand_id,item.id,job_type,'queued',p_provider,p_model,item.id||':'||next_revision::text||':'||job_type::text||':v2','queued',0,
    p_input||jsonb_build_object('contentRevision',next_revision,'regenerationDirection',btrim(p_direction),'regenerationMode',p_mode,'sourceMediaAssetId',source_asset_id));
  insert into public.learning_signals (organization_id,brand_id,content_item_id,signal_type,dimension,value,weight,source,created_by)
  values (item.organization_id,item.brand_id,item.id,'regenerated',case when p_mode='copy' then 'copy' when p_mode in ('update_design','reimagine') then 'image_design' else 'creative_direction' end,
    jsonb_build_object('direction',btrim(p_direction),'mode',p_mode,'previousRevision',p_expected_revision,'newRevision',next_revision,'parentMediaAssetId',source_asset_id),0.5,'shared_review',auth.uid());
  return item;
end;
$$;

revoke all on function public.request_content_regeneration(uuid,integer,text,text,text,jsonb,text) from public;
grant execute on function public.request_content_regeneration(uuid,integer,text,text,text,jsonb,text) to authenticated;
