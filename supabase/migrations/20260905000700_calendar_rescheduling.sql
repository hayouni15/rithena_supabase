-- T07: guarded, timezone-ready movement of plan items inside their seven-day plan.

create or replace function public.reschedule_content_plan_item(
  p_content_item_id uuid,
  p_expected_revision integer,
  p_planned_for date,
  p_proposed_publish_at timestamptz
) returns public.content_items
language plpgsql security definer set search_path = '' as $$
declare
  v_item public.content_items;
  v_plan public.content_plans;
begin
  select * into v_item from public.content_items where id=p_content_item_id for update;
  if v_item.id is null or not public.is_organization_member(v_item.organization_id) then
    raise exception 'Content item unavailable' using errcode='42501';
  end if;
  if v_item.content_revision <> p_expected_revision then
    raise exception 'Content item changed' using errcode='40001';
  end if;
  if v_item.status not in ('draft_plan','planned') or v_item.content_plan_id is null then
    raise exception 'Content item cannot be rescheduled in its current state' using errcode='22023';
  end if;
  select * into v_plan from public.content_plans where id=v_item.content_plan_id and organization_id=v_item.organization_id;
  if v_plan.id is null or p_planned_for not between v_plan.starts_on and v_plan.ends_on or p_proposed_publish_at is null then
    raise exception 'Choose a date inside this content plan' using errcode='22023';
  end if;
  update public.content_items set planned_for=p_planned_for, proposed_publish_at=p_proposed_publish_at
    where id=v_item.id returning * into v_item;
  return v_item;
end;
$$;

revoke all on function public.reschedule_content_plan_item(uuid,integer,date,timestamptz) from public, anon;
grant execute on function public.reschedule_content_plan_item(uuid,integer,date,timestamptz) to authenticated;
