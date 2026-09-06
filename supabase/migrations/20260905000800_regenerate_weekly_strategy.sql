-- Replace an editable week atomically while preserving the previous plan as history.

drop function if exists public.create_weekly_content_plan(uuid,date,text,jsonb,jsonb);

create function public.create_weekly_content_plan(
  p_brand_id uuid, p_starts_on date, p_strategy_summary text, p_strategy_inputs jsonb, p_items jsonb, p_replace boolean default false
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_brand public.brands;
  v_plan_id uuid;
  v_item jsonb;
  v_ends_on date := p_starts_on + 6;
  v_version integer;
begin
  select * into v_brand from public.brands where id=p_brand_id for update;
  if v_brand.id is null or not public.is_organization_member(v_brand.organization_id) then
    raise exception 'Brand unavailable' using errcode='42501';
  end if;
  if p_starts_on is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 21 then
    raise exception 'Invalid weekly plan' using errcode='22023';
  end if;
  select id into v_plan_id from public.content_plans
    where brand_id=p_brand_id and starts_on=p_starts_on and ends_on=v_ends_on and status in ('draft','ready','active')
    order by version desc limit 1;
  if v_plan_id is not null and not p_replace then return v_plan_id; end if;

  if exists (
    select 1 from jsonb_array_elements(p_items) item
    where (item->>'planned_for')::date not between p_starts_on and v_ends_on
      or coalesce(btrim(item->>'working_title'),'')=''
      or coalesce(jsonb_array_length(item->'platform_targets'),0)=0
      or not exists(select 1 from public.content_pillars cp where cp.id=(item->>'content_pillar_id')::uuid and cp.brand_id=p_brand_id and cp.is_active)
  ) then raise exception 'Invalid weekly plan item' using errcode='22023'; end if;

  select coalesce(max(version),0)+1 into v_version from public.content_plans where brand_id=p_brand_id and starts_on=p_starts_on and ends_on=v_ends_on;
  if v_plan_id is not null then
    update public.content_plans set status='archived' where id=v_plan_id;
  end if;
  insert into public.content_plans(organization_id,brand_id,starts_on,ends_on,status,strategy_summary,strategy_inputs,version,created_by)
    values(v_brand.organization_id,p_brand_id,p_starts_on,v_ends_on,'ready',p_strategy_summary,coalesce(p_strategy_inputs,'{}'),v_version,auth.uid()) returning id into v_plan_id;
  for v_item in select value from jsonb_array_elements(p_items) loop
    insert into public.content_items(organization_id,brand_id,content_plan_id,content_pillar_id,planned_for,proposed_publish_at,platform_targets,format,archetype_key,working_title,hook,concept,creative_direction,call_to_action,risk_level,created_by)
    values(v_brand.organization_id,p_brand_id,v_plan_id,(v_item->>'content_pillar_id')::uuid,(v_item->>'planned_for')::date,(v_item->>'proposed_publish_at')::timestamptz,
      array(select jsonb_array_elements_text(v_item->'platform_targets'))::public.social_platform[],(v_item->>'format')::public.content_format,v_item->>'archetype_key',v_item->>'working_title',v_item->>'hook',v_item->>'concept',v_item->>'creative_direction',v_item->>'call_to_action',(v_item->>'risk_level')::public.risk_level,auth.uid());
  end loop;
  return v_plan_id;
end;
$$;

revoke all on function public.create_weekly_content_plan(uuid,date,text,jsonb,jsonb,boolean) from public, anon;
grant execute on function public.create_weekly_content_plan(uuid,date,text,jsonb,jsonb,boolean) to authenticated;
