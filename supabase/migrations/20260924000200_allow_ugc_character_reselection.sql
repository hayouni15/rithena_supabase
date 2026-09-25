-- The calendar exposes creator selection for existing unpublished creatives as
-- well as new plans. Permit reselection whenever production is not actively
-- running, while continuing to protect publishing and immutable states.
create or replace function public.confirm_content_item_ugc_character(p_content_item_id uuid,p_character_id uuid) returns public.content_items
language plpgsql security definer set search_path='' as $$
declare
  v_item public.content_items;
  v_generation_active boolean;
begin
  select * into v_item from public.content_items where id=p_content_item_id for update;
  if v_item.id is null or not public.is_organization_member(v_item.organization_id) then
    raise exception 'Content item unavailable' using errcode='42501';
  end if;
  if v_item.creative_mode not in ('ugc','product_ugc') or v_item.format<>'short_video' then
    raise exception 'This creative is not a UGC video.' using errcode='22023';
  end if;
  if v_item.status in ('approved','scheduled','publishing','published','archived') then
    raise exception 'The creator cannot be changed after approval.' using errcode='55000';
  end if;

  select exists (
    select 1 from public.generation_jobs j
    where j.content_item_id=v_item.id
      and j.state in ('queued','running','retrying','waiting_external')
      and j.updated_at > now() - case when j.state='waiting_external' then interval '45 minutes' else interval '15 minutes' end
  ) into v_generation_active;
  if v_generation_active then
    raise exception 'Wait for the active generation to finish before changing the creator.' using errcode='55000';
  end if;

  if not exists(select 1 from public.characters where id=p_character_id and is_active) then
    raise exception 'That creator is no longer available.' using errcode='22023';
  end if;
  update public.content_items set selected_ugc_character_id=p_character_id,ugc_character_selection_confirmed=true
  where id=v_item.id returning * into v_item;
  return v_item;
end;
$$;
