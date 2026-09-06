alter table public.brands add column brain_revision integer not null default 1 check(brain_revision > 0);
alter table public.brand_facts add column fact_revision integer not null default 1 check(fact_revision > 0);
alter table public.brand_facts add column confirmed_by uuid references public.profiles(id) on delete set null;
-- Clients cannot forge verification or mutate source provenance by writing the table.
revoke insert,update,delete on public.brand_facts from authenticated;

create function public.save_brand_brain(p_brand_id uuid,p_revision integer,p_data jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare b public.brands; e jsonb; g text; n integer := 0; posts integer;
begin
  select * into b from public.brands where id=p_brand_id for update;
  if b.id is null or not public.is_organization_member(b.organization_id) then raise exception 'Brand unavailable' using errcode='42501'; end if;
  if p_revision is null or p_revision <> b.brain_revision then raise exception 'Brand changed' using errcode='40001'; end if;
  if coalesce(length(btrim(p_data->>'name')),0) not between 1 and 160 or coalesce(length(btrim(p_data->>'description')),0) not between 1 and 2400
    or not exists(select 1 from pg_timezone_names where name=p_data->>'timezone') or octet_length(p_data::text)>150000 then raise exception 'Invalid brand' using errcode='22023'; end if;
  posts := case p_data->>'frequency' when '3_per_week' then 3 when '5_per_week' then 5 when 'daily' then 7 when 'custom' then (p_data->>'postsPerWeek')::integer end;
  if posts is null or posts not between 1 and 21 then raise exception 'Invalid frequency' using errcode='22023'; end if;
  if coalesce(jsonb_array_length(p_data->'goals'),0)=0 then raise exception 'Choose a goal' using errcode='22023'; end if;
  if jsonb_typeof(p_data->'pillars') is distinct from 'array' or jsonb_array_length(p_data->'pillars') > 12 then raise exception 'Invalid pillars' using errcode='22023'; end if;
  if jsonb_array_length(p_data->'pillars')>0 and (
    (select sum((x->>'percentage')::numeric) from jsonb_array_elements(p_data->'pillars') x) is distinct from 100::numeric
    or exists(select 1 from jsonb_array_elements(p_data->'pillars') x where (x->>'percentage')::numeric <> trunc((x->>'percentage')::numeric) or coalesce(length(btrim(x->>'name')),0)=0)
    or (select count(*) from jsonb_array_elements(p_data->'pillars')) <> (select count(distinct lower(x->>'name')) from jsonb_array_elements(p_data->'pillars') x)
  ) then raise exception 'Pillars must be unique and total 100' using errcode='22023'; end if;
  update public.brands set name=p_data->>'name',description=p_data->>'description',website_url=p_data->>'websiteUrl',industry=p_data->>'industry',geography=p_data->>'geography',timezone=p_data->>'timezone',brain_revision=brain_revision+1 where id=b.id;
  for e in select value from jsonb_array_elements(jsonb_build_array(
    jsonb_build_object('category','audience','key','primary','value',p_data->'audience'),
    jsonb_build_object('category','voice','key','examples','value',p_data->'voiceExamples'),
    jsonb_build_object('category','voice','key','banned_phrases','value',p_data->'bannedPhrases'),
    jsonb_build_object('category','offerings','key','products_services','value',p_data->'products'),
    jsonb_build_object('category','creative','key','personality','value',p_data->'personalities'),
    jsonb_build_object('category','visual','key','identity','value',p_data->'visual'),
    jsonb_build_object('category','publishing','key','frequency','value',jsonb_build_object('preset',p_data->>'frequency','postsPerWeek',posts))
  )) loop
    insert into public.brand_preferences(organization_id,brand_id,category,key,value,is_explicit,last_observed_at)
      values(b.organization_id,b.id,e->>'category',e->>'key',e->'value',true,now())
      on conflict(brand_id,category,key) do update set value=excluded.value,is_explicit=true,last_observed_at=now();
  end loop;
  update public.goals set is_active=false where brand_id=b.id;
  for g in select distinct value from jsonb_array_elements_text(p_data->'goals') loop
    n:=n+1;
    insert into public.goals(organization_id,brand_id,goal_type,priority) values(b.organization_id,b.id,g::public.goal_type,n)
      on conflict(brand_id,goal_type) do update set is_active=true,priority=excluded.priority;
  end loop;
  -- Retain historical pillar IDs referenced by existing content.
  update public.content_pillars set is_active=false where brand_id=b.id;
  for e in select value from jsonb_array_elements(p_data->'pillars') loop
    insert into public.content_pillars(organization_id,brand_id,name,description,target_percentage)
      values(b.organization_id,b.id,e->>'name',e->>'description',(e->>'percentage')::numeric)
      on conflict(brand_id,name) do update set description=excluded.description,target_percentage=excluded.target_percentage,is_active=true;
  end loop;
  return b.brain_revision+1;
end;
$$;
revoke all on function public.save_brand_brain(uuid,integer,jsonb) from public;
grant execute on function public.save_brand_brain(uuid,integer,jsonb) to authenticated;

create function public.save_brand_fact(p_brand_id uuid,p_fact_id uuid,p_revision integer,p_value text,p_confirm boolean,p_source_url text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare b public.brands; f public.brand_facts; source_id uuid;
begin
  select * into b from public.brands where id=p_brand_id for update;
  if b.id is null or not public.is_organization_member(b.organization_id) then raise exception 'Brand unavailable' using errcode='42501'; end if;
  if coalesce(length(btrim(p_value)),0) not between 1 and 1000 or p_confirm is null or p_fact_id is null then raise exception 'Invalid fact' using errcode='22023'; end if;
  select * into f from public.brand_facts where id=p_fact_id and brand_id=b.id for update;
  if p_revision is null or p_revision <> coalesce(f.fact_revision,0) then raise exception 'Fact changed' using errcode='40001'; end if;
  if f.id is null then
    if p_source_url is not null and (length(p_source_url)>2048 or p_source_url !~ '^https?://') then raise exception 'Invalid source' using errcode='22023'; end if;
    insert into public.brand_sources(organization_id,brand_id,source_type,source_label,source_url,ingestion_status)
      values(b.organization_id,b.id,'manual','Owner-supplied fact',p_source_url,'succeeded') returning id into source_id;
    insert into public.brand_facts(id,organization_id,brand_id,brand_source_id,key,value,source_url)
      values(p_fact_id,b.organization_id,b.id,source_id,'manual.'||p_fact_id::text,btrim(p_value),p_source_url) returning * into f;
  end if;
  -- Confirmation is explicit for this exact value. Editing defaults back to unverified.
  update public.brand_facts set value=btrim(p_value),fact_revision=fact_revision+1,
    verification_status=case when p_confirm then 'user_confirmed'::public.fact_verification_status else 'unverified'::public.fact_verification_status end,
    last_verified_at=case when p_confirm then now() else null end,confirmed_by=case when p_confirm then auth.uid() else null end
    where id=f.id returning * into f;
  return to_jsonb(f);
end;
$$;
revoke all on function public.save_brand_fact(uuid,uuid,integer,text,boolean,text) from public;
grant execute on function public.save_brand_fact(uuid,uuid,integer,text,boolean,text) to authenticated;
