-- Account-scoped drafts and a single atomic, retry-safe completion operation.
create table public.onboarding_drafts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  payload jsonb not null check (jsonb_typeof(payload) = 'object' and octet_length(payload::text) <= 150000),
  revision integer not null default 1 check (revision > 0),
  updated_at timestamptz not null default now()
);
alter table public.onboarding_drafts enable row level security;
create policy "Read own onboarding draft" on public.onboarding_drafts for select to authenticated using (user_id = (select auth.uid()));
grant select on public.onboarding_drafts to authenticated;
grant all on public.onboarding_drafts to service_role;
revoke all on public.onboarding_drafts from anon;

create function public.save_onboarding_draft(p_payload jsonb, p_revision integer) returns integer
language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_revision integer;
begin
  if v_user is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_user::text, 0));
  select revision into v_revision from public.onboarding_drafts where user_id = v_user;
  if p_revision is null or p_revision <> coalesce(v_revision, 0) then raise exception 'Draft changed' using errcode = '40001'; end if;
  insert into public.onboarding_drafts(user_id, payload, revision) values(v_user, p_payload, 1)
    on conflict(user_id) do update set payload = excluded.payload, revision = onboarding_drafts.revision + 1, updated_at = now()
    returning revision into v_revision;
  return v_revision;
end;
$$;
revoke all on function public.save_onboarding_draft(jsonb, integer) from public;
grant execute on function public.save_onboarding_draft(jsonb, integer) to authenticated;

create function public.complete_onboarding(p_payload jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid(); v_org uuid; v_brand uuid; v_source uuid;
  a jsonb := p_payload->'analysis'; v_timezone text := p_payload->>'timezone';
  v_mode public.autopilot_mode := (p_payload->>'autopilotMode')::public.autopilot_mode;
  v_posts integer; entry jsonb; goal text; n integer := 0;
begin
  if v_user is null then raise exception 'Authentication required' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_user::text, 0));
  if not exists(select 1 from pg_timezone_names where name = v_timezone) then raise exception 'Invalid timezone' using errcode = '22023'; end if;
  if coalesce(length(btrim(p_payload->>'organizationName')),0) not between 1 and 160
    or coalesce(length(btrim(a->>'companyName')),0) not between 1 and 160
    or coalesce(length(btrim(a->>'description')),0) not between 1 and 2400
    or coalesce(p_payload->>'websiteUrl','') !~ '^https?://'
    or v_mode is null or octet_length(p_payload::text) > 150000 then
    raise exception 'Invalid brand setup' using errcode = '22023';
  end if;
  v_posts := case p_payload->>'frequency' when '3_per_week' then 3 when '5_per_week' then 5 when 'daily' then 7
    when 'custom' then (p_payload->>'customPostsPerWeek')::integer end;
  if v_posts is null or v_posts not between 1 and 21 then raise exception 'Invalid frequency' using errcode = '22023'; end if;
  if coalesce(jsonb_array_length(p_payload->'goals'),0) = 0
    or coalesce(jsonb_array_length(p_payload->'channels'),0) = 0
    or coalesce(jsonb_array_length(p_payload->'creativePersonalities'),0) = 0 then raise exception 'Missing preferences' using errcode = '22023'; end if;
  if exists(select 1 from jsonb_array_elements_text(p_payload->'channels') x where x not in ('Instagram','Facebook','LinkedIn','TikTok','YouTube'))
    or exists(select 1 from jsonb_array_elements_text(p_payload->'creativePersonalities') x where x not in ('Editorial','Cinematic','Minimal','Bold','Warm','Playful','Human','Product-focused')) then raise exception 'Invalid preferences' using errcode = '22023'; end if;

  -- Do not let an invited member's onboarding rewrite somebody else's workspace.
  select b.id into v_brand from public.brands b join public.organization_members m on m.organization_id = b.organization_id
    where b.created_by = v_user and m.user_id = v_user and b.onboarding_completed_at is not null
    order by b.onboarding_completed_at desc limit 1;
  if v_brand is not null then return v_brand; end if;
  insert into public.profiles(id, timezone) values(v_user,v_timezone) on conflict(id) do update set timezone = excluded.timezone;
  select o.id into v_org from public.organizations o join public.organization_members m on m.organization_id=o.id
    where o.created_by = v_user and m.user_id=v_user and m.role in ('owner','admin') order by o.created_at limit 1;
  if v_org is null then
    insert into public.organizations(name, slug, timezone, created_by)
      values(p_payload->>'organizationName', 'workspace-' || v_user::text, v_timezone, v_user) returning id into v_org;
  else
    update public.organizations set name=p_payload->>'organizationName', timezone=v_timezone where id=v_org;
  end if;
  select id into v_brand from public.brands where organization_id=v_org and created_by=v_user and onboarding_completed_at is null order by created_at limit 1;
  if v_brand is null then
    insert into public.brands(organization_id,name,slug,created_by) values(v_org,a->>'companyName','brand-'||v_user::text,v_user) returning id into v_brand;
  end if;
  update public.brands set name=a->>'companyName', description=a->>'description', website_url=p_payload->>'websiteUrl',
    industry=a->>'industry', geography=a->>'geography', timezone=v_timezone, default_autopilot_mode=v_mode where id=v_brand;
  select id into v_source from public.brand_sources where brand_id=v_brand and source_type='website' order by created_at limit 1;
  if v_source is null then
    insert into public.brand_sources(organization_id,brand_id,source_type) values(v_org,v_brand,'website') returning id into v_source;
  end if;
  update public.brand_sources set source_url=p_payload->>'websiteUrl', source_label='Primary website', ingestion_status='succeeded',
    extracted_data=a, last_ingested_at=now(), error_code=null, error_message=null where id=v_source;
  -- Retry of a partial legacy setup replaces only the extracted, unconfirmed facts.
  delete from public.brand_facts where brand_id=v_brand and verification_status='unverified';
  for entry in select value from jsonb_array_elements(coalesce(a->'factualClaims','[]'::jsonb)) loop
    n := n+1;
    insert into public.brand_facts(organization_id,brand_id,brand_source_id,key,value,confidence,source_url,source_excerpt)
      values(v_org,v_brand,v_source,'claim.'||n,entry->>'claim',coalesce((entry->>'confidence')::numeric,0),coalesce(nullif(entry->>'sourceUrl',''),p_payload->>'websiteUrl'),entry->>'sourceExcerpt')
      on conflict(brand_id,key) do nothing;
  end loop;
  for entry in select value from jsonb_array_elements(jsonb_build_array(
    jsonb_build_object('category','creative','key','personality','value',p_payload->'creativePersonalities'),
    jsonb_build_object('category','publishing','key','channels','value',(select jsonb_agg(lower(x)) from jsonb_array_elements_text(p_payload->'channels') x)),
    jsonb_build_object('category','publishing','key','frequency','value',jsonb_build_object('preset',p_payload->>'frequency','postsPerWeek',v_posts)),
    jsonb_build_object('category','audience','key','primary','value',coalesce(a->'targetAudience','""'::jsonb)),
    jsonb_build_object('category','offerings','key','products_services','value',coalesce(a->'productsServices','[]'::jsonb)),
    jsonb_build_object('category','voice','key','examples','value',coalesce(a->'toneVoiceExamples','[]'::jsonb)),
    jsonb_build_object('category','visual','key','identity','value',jsonb_build_object('colors',a->'colors','typographyClues',a->'typographyClues','photographyStyle',a->'photographyStyle','visualKeywords',a->'visualKeywords','logoUrl',a->'logoUrl'))
  )) loop
    insert into public.brand_preferences(organization_id,brand_id,category,key,value,is_explicit,evidence_count,last_observed_at)
      values(v_org,v_brand,entry->>'category',entry->>'key',entry->'value',true,1,now())
      on conflict(brand_id,category,key) do update set value=excluded.value,is_explicit=true,last_observed_at=now();
  end loop;
  update public.goals set is_active=false where brand_id=v_brand;
  n := 0;
  for goal in select distinct value from jsonb_array_elements_text(p_payload->'goals') loop
    n := n+1;
    insert into public.goals(organization_id,brand_id,goal_type,priority) values(v_org,v_brand,goal::public.goal_type,n)
      on conflict(brand_id,goal_type) do update set is_active=true,priority=excluded.priority;
  end loop;
  update public.autopilot_policies set is_active=false where brand_id=v_brand;
  insert into public.autopilot_policies(organization_id,brand_id,mode,content_category,risk_level,approval_policy)
    values(v_org,v_brand,v_mode,'evergreen','low',case when v_mode='review_everything' then 'review'::public.approval_policy else 'auto'::public.approval_policy end),
      (v_org,v_brand,v_mode,'factual_claims','medium','review'),(v_org,v_brand,v_mode,'offers_and_promotions','high','review')
    on conflict(brand_id,mode,content_category) do update set approval_policy=excluded.approval_policy,is_active=true;
  update public.brands set status='active',onboarding_completed_at=now() where id=v_brand;
  delete from public.onboarding_drafts where user_id=v_user;
  return v_brand;
end;
$$;
revoke all on function public.complete_onboarding(jsonb) from public;
grant execute on function public.complete_onboarding(jsonb) to authenticated;
