-- Save format and product mode together so calendar edits cannot partially apply.

create or replace function public.guard_content_item_update() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.status is distinct from old.status then
    if coalesce(current_setting('rithena.lifecycle_transition', true), '') <> 'allowed' then
      raise exception 'Use transition_content_item to change status' using errcode = '42501';
    end if;
    if not public.is_content_transition_allowed(old.status, new.status) then
      raise exception 'Invalid content transition: % -> %', old.status, new.status using errcode = '22023';
    end if;
  end if;

  if row(
    new.brand_id, new.content_plan_id, new.campaign_id, new.content_pillar_id,
    new.planned_for, new.platform_targets, new.format, new.archetype_key,
    new.working_title, new.hook, new.concept, new.creative_direction,
    new.call_to_action, new.risk_level, new.creative_mode,
    new.selected_product_id, new.product_selection_confirmed
  ) is distinct from row(
    old.brand_id, old.content_plan_id, old.campaign_id, old.content_pillar_id,
    old.planned_for, old.platform_targets, old.format, old.archetype_key,
    old.working_title, old.hook, old.concept, old.creative_direction,
    old.call_to_action, old.risk_level, old.creative_mode,
    old.selected_product_id, old.product_selection_confirmed
  ) then
    if coalesce(current_setting('rithena.schedule_change', true), '') <> 'allowed'
      or old.status in ('draft_plan', 'planned') then
      new.content_revision := old.content_revision + 1;
    end if;
  elsif new.content_revision <> old.content_revision
    and coalesce(current_setting('rithena.content_revision', true), '') <> 'allowed' then
    raise exception 'Content revision is managed by Rithena' using errcode = '42501';
  end if;
  return new;
end;
$$;

create or replace function public.edit_content_plan_item(
  p_content_item_id uuid,
  p_expected_revision integer,
  p_platform_targets public.social_platform[],
  p_format public.content_format,
  p_working_title text,
  p_hook text,
  p_concept text,
  p_creative_direction text,
  p_call_to_action text,
  p_creative_mode text,
  p_selected_product_id uuid,
  p_product_selection_confirmed boolean
) returns public.content_items
language plpgsql security definer set search_path = '' as $$
declare v_item public.content_items;
begin
  select * into v_item from public.content_items where id = p_content_item_id for update;
  if v_item.id is null or not public.is_organization_member(v_item.organization_id) then
    raise exception 'Content item unavailable' using errcode = '42501';
  end if;
  if v_item.content_revision <> p_expected_revision then
    raise exception 'Content item changed' using errcode = '40001';
  end if;
  if v_item.status not in ('draft_plan', 'planned') then
    raise exception 'Only planned creatives can be edited. Create a new revision from Review once production has started.' using errcode = '22023';
  end if;
  if coalesce(cardinality(p_platform_targets), 0) = 0
    or coalesce(length(btrim(p_working_title)), 0) = 0
    or coalesce(length(btrim(p_concept)), 0) = 0 then
    raise exception 'Add a title, a concept, and at least one destination.' using errcode = '22023';
  end if;
  if p_creative_mode not in ('standard', 'product')
    or (p_creative_mode = 'product' and p_format not in ('image', 'short_video')) then
    raise exception 'Choose a valid creative type.' using errcode = '22023';
  end if;
  if p_creative_mode = 'product' and p_selected_product_id is not null and not exists (
    select 1 from public.products p
    where p.id = p_selected_product_id
      and p.organization_id = v_item.organization_id
      and p.brand_id = v_item.brand_id
      and p.is_active
  ) then
    raise exception 'That product is no longer available.' using errcode = '22023';
  end if;
  if coalesce(p_product_selection_confirmed, false)
    and (p_creative_mode <> 'product' or p_selected_product_id is null) then
    raise exception 'Choose a product before confirming.' using errcode = '22023';
  end if;

  update public.content_items set
    platform_targets = p_platform_targets,
    format = p_format,
    working_title = btrim(p_working_title),
    hook = nullif(btrim(p_hook), ''),
    concept = btrim(p_concept),
    creative_direction = nullif(btrim(p_creative_direction), ''),
    call_to_action = nullif(btrim(p_call_to_action), ''),
    creative_mode = p_creative_mode,
    selected_product_id = case when p_creative_mode = 'product' then p_selected_product_id else null end,
    product_selection_confirmed = case when p_creative_mode = 'product' then coalesce(p_product_selection_confirmed, false) else false end
  where id = v_item.id returning * into v_item;
  return v_item;
end;
$$;

create or replace function public.confirm_content_item_product(
  p_content_item_id uuid,
  p_product_id uuid
) returns public.content_items
language plpgsql security definer set search_path = '' as $$
declare v_item public.content_items;
begin
  select * into v_item from public.content_items where id = p_content_item_id for update;
  if v_item.id is null or not public.is_organization_member(v_item.organization_id) then
    raise exception 'Content item unavailable' using errcode = '42501';
  end if;
  if v_item.creative_mode <> 'product' or v_item.status not in ('draft_plan', 'planned', 'failed') then
    raise exception 'This product creative cannot be changed.' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.products p
    where p.id = p_product_id
      and p.organization_id = v_item.organization_id
      and p.brand_id = v_item.brand_id
      and p.is_active
  ) then
    raise exception 'That product is no longer available.' using errcode = '22023';
  end if;
  update public.content_items
  set selected_product_id = p_product_id, product_selection_confirmed = true
  where id = v_item.id returning * into v_item;
  return v_item;
end;
$$;

revoke all on function public.edit_content_plan_item(uuid,integer,public.social_platform[],public.content_format,text,text,text,text,text,text,uuid,boolean) from public, anon;
grant execute on function public.edit_content_plan_item(uuid,integer,public.social_platform[],public.content_format,text,text,text,text,text,text,uuid,boolean) to authenticated;
revoke all on function public.confirm_content_item_product(uuid,uuid) from public, anon;
grant execute on function public.confirm_content_item_product(uuid,uuid) to authenticated;
