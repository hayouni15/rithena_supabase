-- UGC videos remain short_video content items and add an explicitly selected,
-- curated creator profile. The profile is creative direction, not a claim that
-- a real customer endorsed or used the advertised product.

create table public.ugc_characters (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
  display_name text not null check (length(btrim(display_name)) between 1 and 80),
  description text not null default '',
  presentation_style text not null,
  apparent_age_range text not null,
  gender_presentation text not null,
  languages text[] not null default '{English}',
  accents text[] not null default '{}',
  setting text not null,
  portrait_url text,
  preview_url text,
  voice_preview_url text,
  performance_prompt text not null,
  is_active boolean not null default true,
  position integer not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.ugc_characters enable row level security;
create policy "Authenticated users can view active UGC characters"
  on public.ugc_characters for select to authenticated using (is_active);
revoke all on public.ugc_characters from anon;
grant select on public.ugc_characters to authenticated;

insert into public.ugc_characters
  (slug, display_name, description, presentation_style, apparent_age_range, gender_presentation, accents, setting, performance_prompt, position)
values
  ('maya-warm-guide', 'Maya', 'Warm, candid and reassuring. A natural fit for wellness, food and lifestyle stories.', 'warm and conversational', 'late 20s–30s', 'woman', array['North American'], 'bright lived-in apartment', 'A woman in her early thirties with a warm, expressive presence, natural skin texture and understated everyday styling. She speaks directly to a phone camera with relaxed confidence, subtle hand gestures, natural blinks and small conversational pauses.', 10),
  ('jordan-practical-expert', 'Jordan', 'Clear, grounded and knowledgeable without feeling scripted.', 'calm expert', '30s', 'man', array['North American'], 'modern home office', 'A man in his thirties with an approachable expert presence and casual smart clothing. He speaks clearly to a phone camera, with restrained natural gestures, realistic breathing, small head movements and an unforced conversational cadence.', 20),
  ('nia-energetic-creator', 'Nia', 'Bright, quick and expressive for discoveries, demos and energetic hooks.', 'energetic creator', '20s', 'woman', array['North American'], 'sunlit kitchen', 'A woman in her twenties with bright creator energy, contemporary casual styling and expressive but credible delivery. She speaks to a handheld phone camera with lively micro-expressions, natural pacing and authentic movement, never theatrical or over-rehearsed.', 30),
  ('alex-premium-minimal', 'Alex', 'Composed and design-conscious for premium products and services.', 'premium and composed', '30s–40s', 'androgynous', array['International English'], 'quiet design-led studio', 'An androgynous presenter in their late thirties with a composed, modern presence and minimal premium styling. They speak directly to camera in a measured, human cadence with natural pauses, subtle gestures and realistic facial movement.', 40),
  ('sofia-friendly-founder', 'Sofia', 'Thoughtful and personal for founder-style explanations and brand stories.', 'thoughtful founder', '30s', 'woman', array['Latina North American'], 'small creative workspace', 'A Latina woman in her thirties with a thoughtful founder-like presence, authentic everyday styling and an open, friendly expression. She speaks naturally to a phone camera with genuine pauses, small gestures and calm conviction.', 50),
  ('marcus-confident-coach', 'Marcus', 'Direct and motivating for problem/solution and educational content.', 'confident coach', '30s–40s', 'man', array['North American'], 'casual studio corner', 'A Black man in his late thirties with a confident, supportive coaching presence and relaxed casual clothing. He delivers concise advice directly to a phone camera with natural breath, believable emphasis and grounded hand gestures.', 60)
on conflict (slug) do nothing;

alter table public.content_items drop constraint if exists content_items_creative_mode_check;
alter table public.content_items
  add constraint content_items_creative_mode_check check (creative_mode in ('standard','product','ugc')),
  add column selected_ugc_character_id uuid references public.ugc_characters(id) on delete set null,
  add column ugc_character_selection_confirmed boolean not null default false,
  add constraint content_items_ugc_mode_check check (
    (creative_mode = 'ugc' and format = 'short_video') or creative_mode <> 'ugc'
  ),
  add constraint content_items_ugc_confirmation_check check (
    not ugc_character_selection_confirmed or (creative_mode = 'ugc' and selected_ugc_character_id is not null)
  );

create or replace function public.confirm_content_item_ugc_character(
  p_content_item_id uuid,
  p_character_id uuid
) returns public.content_items
language plpgsql security definer set search_path = '' as $$
declare v_item public.content_items;
begin
  select * into v_item from public.content_items where id = p_content_item_id for update;
  if v_item.id is null or not public.is_organization_member(v_item.organization_id) then
    raise exception 'Content item unavailable' using errcode = '42501';
  end if;
  if v_item.creative_mode <> 'ugc' or v_item.format <> 'short_video'
    or v_item.status not in ('draft_plan', 'planned', 'failed') then
    raise exception 'This UGC character cannot be changed.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.ugc_characters where id = p_character_id and is_active) then
    raise exception 'That creator is no longer available.' using errcode = '22023';
  end if;
  update public.content_items set
    selected_ugc_character_id = p_character_id,
    ugc_character_selection_confirmed = true
  where id = v_item.id returning * into v_item;
  return v_item;
end;
$$;

revoke all on function public.confirm_content_item_ugc_character(uuid,uuid) from public, anon;
grant execute on function public.confirm_content_item_ugc_character(uuid,uuid) to authenticated;

-- Replace the plan-edit RPC with UGC-aware parameters while retaining the
-- atomic revision and tenant checks established by the product workflow.
drop function if exists public.edit_content_plan_item(uuid,integer,public.social_platform[],public.content_format,text,text,text,text,text,text,uuid,boolean);
create function public.edit_content_plan_item(
  p_content_item_id uuid, p_expected_revision integer,
  p_platform_targets public.social_platform[], p_format public.content_format,
  p_working_title text, p_hook text, p_concept text, p_creative_direction text,
  p_call_to_action text, p_creative_mode text, p_selected_product_id uuid,
  p_product_selection_confirmed boolean, p_selected_ugc_character_id uuid,
  p_ugc_character_selection_confirmed boolean
) returns public.content_items
language plpgsql security definer set search_path = '' as $$
declare v_item public.content_items;
begin
  select * into v_item from public.content_items where id=p_content_item_id for update;
  if v_item.id is null or not public.is_organization_member(v_item.organization_id) then raise exception 'Content item unavailable' using errcode='42501'; end if;
  if v_item.content_revision <> p_expected_revision then raise exception 'Content item changed' using errcode='40001'; end if;
  if v_item.status not in ('draft_plan','planned') then raise exception 'Only planned creatives can be edited. Create a new revision from Review once production has started.' using errcode='22023'; end if;
  if coalesce(cardinality(p_platform_targets),0)=0 or coalesce(length(btrim(p_working_title)),0)=0 or coalesce(length(btrim(p_concept)),0)=0 then raise exception 'Add a title, a concept, and at least one destination.' using errcode='22023'; end if;
  if p_creative_mode not in ('standard','product','ugc')
    or (p_creative_mode='product' and p_format not in ('image','short_video'))
    or (p_creative_mode='ugc' and p_format <> 'short_video') then raise exception 'Choose a valid creative type.' using errcode='22023'; end if;
  if p_creative_mode='product' and p_selected_product_id is not null and not exists(select 1 from public.products p where p.id=p_selected_product_id and p.organization_id=v_item.organization_id and p.brand_id=v_item.brand_id and p.is_active) then raise exception 'That product is no longer available.' using errcode='22023'; end if;
  if p_creative_mode='ugc' and p_selected_ugc_character_id is not null and not exists(select 1 from public.ugc_characters c where c.id=p_selected_ugc_character_id and c.is_active) then raise exception 'That creator is no longer available.' using errcode='22023'; end if;
  update public.content_items set
    platform_targets=p_platform_targets, format=p_format, working_title=btrim(p_working_title),
    hook=nullif(btrim(p_hook),''), concept=btrim(p_concept), creative_direction=nullif(btrim(p_creative_direction),''),
    call_to_action=nullif(btrim(p_call_to_action),''), creative_mode=p_creative_mode,
    selected_product_id=case when p_creative_mode='product' then p_selected_product_id else null end,
    product_selection_confirmed=case when p_creative_mode='product' then coalesce(p_product_selection_confirmed,false) else false end,
    selected_ugc_character_id=case when p_creative_mode='ugc' then p_selected_ugc_character_id else null end,
    ugc_character_selection_confirmed=case when p_creative_mode='ugc' then coalesce(p_ugc_character_selection_confirmed,false) else false end
  where id=v_item.id returning * into v_item;
  return v_item;
end;
$$;

revoke all on function public.edit_content_plan_item(uuid,integer,public.social_platform[],public.content_format,text,text,text,text,text,text,uuid,boolean,uuid,boolean) from public, anon;
grant execute on function public.edit_content_plan_item(uuid,integer,public.social_platform[],public.content_format,text,text,text,text,text,text,uuid,boolean,uuid,boolean) to authenticated;

-- Include UGC selection in the canonical revision guard.
create or replace function public.guard_content_item_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.status is distinct from old.status then
    if coalesce(current_setting('rithena.lifecycle_transition', true), '') <> 'allowed' then raise exception 'Use transition_content_item to change status' using errcode='42501'; end if;
    if not public.is_content_transition_allowed(old.status,new.status) then raise exception 'Invalid content transition: % -> %',old.status,new.status using errcode='22023'; end if;
  end if;
  if row(new.brand_id,new.content_plan_id,new.campaign_id,new.content_pillar_id,new.planned_for,new.platform_targets,new.format,new.archetype_key,new.working_title,new.hook,new.concept,new.creative_direction,new.call_to_action,new.risk_level,new.creative_mode,new.selected_product_id,new.product_selection_confirmed,new.selected_ugc_character_id,new.ugc_character_selection_confirmed)
    is distinct from row(old.brand_id,old.content_plan_id,old.campaign_id,old.content_pillar_id,old.planned_for,old.platform_targets,old.format,old.archetype_key,old.working_title,old.hook,old.concept,old.creative_direction,old.call_to_action,old.risk_level,old.creative_mode,old.selected_product_id,old.product_selection_confirmed,old.selected_ugc_character_id,old.ugc_character_selection_confirmed) then
    if coalesce(current_setting('rithena.schedule_change',true),'') <> 'allowed' or old.status in ('draft_plan','planned') then new.content_revision := old.content_revision + 1; end if;
  elsif new.content_revision <> old.content_revision and coalesce(current_setting('rithena.content_revision',true),'') <> 'allowed' then raise exception 'Content revision is managed by Rithena' using errcode='42501'; end if;
  return new;
end;
$$;
