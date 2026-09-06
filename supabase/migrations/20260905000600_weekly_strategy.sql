-- T06: structured strategy seeds and atomic, idempotent seven-day plan creation.

alter table public.content_items
  add column if not exists proposed_publish_at timestamptz;

insert into public.industry_playbooks(key,name,description,strategy_config) values
  ('realtor','Real estate','Listings, neighborhoods, buyer and seller education, market context, proof, and behind-the-scenes.', '{"pillars":["listings","neighborhood","buyer education","seller education","market commentary","social proof","behind the scenes"]}'),
  ('fitness','Fitness','Education, workout guidance, transformation, member stories, instructor personality, offers, and motivation.', '{"pillars":["education","workout tips","transformation","member stories","instructor personality","offers","motivation"]}'),
  ('home_services','Home services','Before-and-after work, maintenance education, mistakes, project showcases, seasonal reminders, proof, and service explanations.', '{"pillars":["before and after","maintenance education","common mistakes","project showcases","seasonal reminders","proof","service explanations"]}'),
  ('hospitality','Cafe and restaurant','Product beauty, rituals, behind the scenes, staff, education, offers, and community.', '{"pillars":["product beauty","rituals","behind the scenes","staff","education","offers","community"]}')
on conflict (key) do update set name=excluded.name, description=excluded.description, strategy_config=excluded.strategy_config, is_active=true;

insert into public.creative_archetypes(key,name,description,supported_formats,supported_goals,risk_level,structure,required_inputs) values
  ('problem_solution','Problem to solution','Recognizable pain, useful solution, concrete payoff, and CTA.',array['short_video','carousel']::public.content_format[],array['get_leads','promote_products','stay_visible']::public.goal_type[],'low','["hook","problem","solution","payoff","cta"]','{audience_problem,solution,benefit}'),
  ('mini_tutorial','Mini tutorial','Outcome first, concise steps, result, and save prompt.',array['short_video','carousel']::public.content_format[],array['educate','build_authority','grow_audience']::public.goal_type[],'low','["outcome","steps","result","cta"]','{topic,outcome}'),
  ('three_reasons','Three reasons','A fast, structured list that earns attention with useful specifics.',array['carousel','short_video']::public.content_format[],array['educate','build_authority','grow_audience']::public.goal_type[],'low','["hook","reason_1","reason_2","reason_3","cta"]','{topic}'),
  ('myth_fact','Myth versus fact','Correct a misconception without manufacturing fear.',array['image','carousel','short_video']::public.content_format[],array['educate','build_authority']::public.goal_type[],'medium','["myth","fact","why_it_matters","cta"]','{topic,verified_fact}'),
  ('mistake','Common mistake','Explain a real mistake and a constructive correction.',array['image','carousel','short_video']::public.content_format[],array['educate','build_authority','get_leads']::public.goal_type[],'medium','["hook","mistake","correction","cta"]','{topic}'),
  ('product_demo','Product or service demo','Show how an offering works and the supported benefit.',array['short_video','carousel']::public.content_format[],array['promote_products','get_leads']::public.goal_type[],'medium','["hook","demo","benefit","cta"]','{offering,benefit}'),
  ('pov','Point of view','A concise audience situation with a relatable payoff.',array['image','short_video']::public.content_format[],array['stay_visible','grow_audience']::public.goal_type[],'low','["pov","situation","payoff","cta"]','{audience,topic}')
on conflict (key) do update set name=excluded.name, description=excluded.description, supported_formats=excluded.supported_formats, supported_goals=excluded.supported_goals, risk_level=excluded.risk_level, structure=excluded.structure, required_inputs=excluded.required_inputs, is_active=true;

create or replace function public.create_weekly_content_plan(
  p_brand_id uuid, p_starts_on date, p_strategy_summary text, p_strategy_inputs jsonb, p_items jsonb
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_brand public.brands;
  v_plan_id uuid;
  v_item jsonb;
  v_ends_on date := p_starts_on + 6;
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
  if v_plan_id is not null then return v_plan_id; end if;

  if exists (
    select 1 from jsonb_array_elements(p_items) item
    where (item->>'planned_for')::date not between p_starts_on and v_ends_on
      or coalesce(btrim(item->>'working_title'),'')=''
      or coalesce(jsonb_array_length(item->'platform_targets'),0)=0
      or not exists(select 1 from public.content_pillars cp where cp.id=(item->>'content_pillar_id')::uuid and cp.brand_id=p_brand_id and cp.is_active)
  ) then raise exception 'Invalid weekly plan item' using errcode='22023'; end if;

  insert into public.content_plans(organization_id,brand_id,starts_on,ends_on,status,strategy_summary,strategy_inputs,created_by)
    values(v_brand.organization_id,p_brand_id,p_starts_on,v_ends_on,'ready',p_strategy_summary,coalesce(p_strategy_inputs,'{}'),auth.uid()) returning id into v_plan_id;
  for v_item in select value from jsonb_array_elements(p_items) loop
    insert into public.content_items(organization_id,brand_id,content_plan_id,content_pillar_id,planned_for,proposed_publish_at,platform_targets,format,archetype_key,working_title,hook,concept,creative_direction,call_to_action,risk_level,created_by)
    values(v_brand.organization_id,p_brand_id,v_plan_id,(v_item->>'content_pillar_id')::uuid,(v_item->>'planned_for')::date,(v_item->>'proposed_publish_at')::timestamptz,
      array(select jsonb_array_elements_text(v_item->'platform_targets'))::public.social_platform[],(v_item->>'format')::public.content_format,v_item->>'archetype_key',v_item->>'working_title',v_item->>'hook',v_item->>'concept',v_item->>'creative_direction',v_item->>'call_to_action',(v_item->>'risk_level')::public.risk_level,auth.uid());
  end loop;
  return v_plan_id;
end;
$$;

revoke all on function public.create_weekly_content_plan(uuid,date,text,jsonb,jsonb) from public, anon;
grant execute on function public.create_weekly_content_plan(uuid,date,text,jsonb,jsonb) to authenticated;
