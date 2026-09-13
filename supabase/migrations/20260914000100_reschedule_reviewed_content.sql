-- Rescheduling changes delivery timing, not the approved creative. Permit it for
-- generated/reviewed content without invalidating its content revision.

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
    new.call_to_action, new.risk_level
  ) is distinct from row(
    old.brand_id, old.content_plan_id, old.campaign_id, old.content_pillar_id,
    old.planned_for, old.platform_targets, old.format, old.archetype_key,
    old.working_title, old.hook, old.concept, old.creative_direction,
    old.call_to_action, old.risk_level
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

create or replace function public.reschedule_content_plan_item(
  p_content_item_id uuid,
  p_expected_revision integer,
  p_planned_for date,
  p_proposed_publish_at timestamptz
) returns public.content_items
language plpgsql security definer set search_path = '' as $$
declare v_item public.content_items; v_plan public.content_plans;
begin
  select * into v_item from public.content_items where id=p_content_item_id for update;
  if v_item.id is null or not public.is_organization_member(v_item.organization_id) then raise exception 'Content item unavailable' using errcode='42501'; end if;
  if v_item.content_revision <> p_expected_revision then raise exception 'Content item changed' using errcode='40001'; end if;
  if v_item.status in ('scheduled','publishing','published','archived') or v_item.content_plan_id is null then
    raise exception 'Undo scheduling before moving this post' using errcode='22023';
  end if;
  select * into v_plan from public.content_plans where id=v_item.content_plan_id and organization_id=v_item.organization_id;
  if v_plan.id is null or p_planned_for not between v_plan.starts_on and v_plan.ends_on or p_proposed_publish_at is null then raise exception 'Choose a date inside this content plan' using errcode='22023'; end if;
  perform set_config('rithena.schedule_change','allowed',true);
  update public.content_items set planned_for=p_planned_for,proposed_publish_at=p_proposed_publish_at where id=v_item.id returning * into v_item;
  return v_item;
end;
$$;

revoke all on function public.reschedule_content_plan_item(uuid,integer,date,timestamptz) from public,anon;
grant execute on function public.reschedule_content_plan_item(uuid,integer,date,timestamptz) to authenticated;
