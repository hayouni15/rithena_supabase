insert into public.creative_recipes(key,version,name,status,schema_version,manifest,is_active)
values (
  'foundation-image', 1, 'Foundation Image', 'experimental', 1,
  '{
    "schemaVersion": 1,
    "id": "foundation-image",
    "version": 1,
    "name": "Foundation Image",
    "status": "experimental",
    "formats": ["image"],
    "goals": ["stay_visible","get_leads","build_authority","educate","grow_audience","promote_products"],
    "industries": ["all"],
    "platforms": ["instagram","facebook","linkedin","tiktok","youtube"],
    "narrative": {"hookFamilies":["direct_benefit","problem_recognition","curiosity"],"requiredContent":["title","cta"]},
    "visual": {"artDirection":"Clean generated visual plate with deterministic brand typography and logo treatment.","compositionFamily":"foundation","subjectPlacement":"adaptive","textDensity":"low"},
    "slots": [
      {"id":"plate","kind":"source_image","required":true},
      {"id":"contrast","kind":"treatment","required":true},
      {"id":"title","kind":"text","required":true},
      {"id":"subtitle","kind":"text","required":false},
      {"id":"cta","kind":"text","required":true},
      {"id":"logo","kind":"logo","required":false}
    ],
    "variants": [
      {"id":"bottom-minimal","label":"Bottom minimal","overrides":{"layout":"bottom_minimal"}},
      {"id":"centered-serif","label":"Centered serif","overrides":{"layout":"centered_serif"}},
      {"id":"left-stacked","label":"Left stacked","overrides":{"layout":"left_stacked"}}
    ],
    "qualityRules": ["safe_zones","text_contrast","logo_integrity","source_plate_has_no_text"]
  }'::jsonb,
  true
)
on conflict(key,version) do update set manifest=excluded.manifest,name=excluded.name,is_active=true;
