-- Let a planner revise one unproduced creative without replacing its entire week.
create or replace function public.edit_content_plan_item(
  p_content_item_id uuid,
  p_expected_revision integer,
  p_platform_targets public.social_platform[],
  p_format public.content_format,
  p_working_title text,
  p_hook text,
  p_concept text,
  p_creative_direction text,
  p_call_to_action text
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
  update public.content_items set
    platform_targets = p_platform_targets,
    format = p_format,
    working_title = btrim(p_working_title),
    hook = nullif(btrim(p_hook), ''),
    concept = btrim(p_concept),
    creative_direction = nullif(btrim(p_creative_direction), ''),
    call_to_action = nullif(btrim(p_call_to_action), '')
  where id = v_item.id returning * into v_item;
  return v_item;
end;
$$;

revoke all on function public.edit_content_plan_item(uuid,integer,public.social_platform[],public.content_format,text,text,text,text,text) from public, anon;
grant execute on function public.edit_content_plan_item(uuid,integer,public.social_platform[],public.content_format,text,text,text,text,text) to authenticated;
