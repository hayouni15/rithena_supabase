-- Product UGC combines an approved creator portrait and product identity images
-- in one short-video job while preserving the canonical short_video format.
alter table public.content_items drop constraint if exists content_items_creative_mode_check;
alter table public.content_items drop constraint if exists content_items_ugc_mode_check;
alter table public.content_items drop constraint if exists content_items_ugc_confirmation_check;
alter table public.content_items add constraint content_items_creative_mode_check check (creative_mode in ('standard','product','ugc','product_ugc'));
alter table public.content_items add constraint content_items_ugc_mode_check check ((creative_mode in ('ugc','product_ugc') and format='short_video') or creative_mode not in ('ugc','product_ugc'));
alter table public.content_items add constraint content_items_ugc_confirmation_check check (not ugc_character_selection_confirmed or (creative_mode in ('ugc','product_ugc') and selected_ugc_character_id is not null));

create or replace function public.confirm_content_item_product(p_content_item_id uuid,p_product_id uuid) returns public.content_items
language plpgsql security definer set search_path='' as $$ declare v_item public.content_items; begin
  select * into v_item from public.content_items where id=p_content_item_id for update;
  if v_item.id is null or not public.is_organization_member(v_item.organization_id) then raise exception 'Content item unavailable' using errcode='42501';end if;
  if v_item.creative_mode not in ('product','product_ugc') or v_item.status not in ('draft_plan','planned','failed') then raise exception 'This product creative cannot be changed.' using errcode='22023';end if;
  if not exists(select 1 from public.products p where p.id=p_product_id and p.organization_id=v_item.organization_id and p.brand_id=v_item.brand_id and p.is_active) then raise exception 'That product is no longer available.' using errcode='22023';end if;
  update public.content_items set selected_product_id=p_product_id,product_selection_confirmed=true where id=v_item.id returning * into v_item;return v_item;
end;$$;

create or replace function public.confirm_content_item_ugc_character(p_content_item_id uuid,p_character_id uuid) returns public.content_items
language plpgsql security definer set search_path='' as $$ declare v_item public.content_items; begin
  select * into v_item from public.content_items where id=p_content_item_id for update;
  if v_item.id is null or not public.is_organization_member(v_item.organization_id) then raise exception 'Content item unavailable' using errcode='42501';end if;
  if v_item.creative_mode not in ('ugc','product_ugc') or v_item.format<>'short_video' or v_item.status not in ('draft_plan','planned','failed') then raise exception 'This UGC character cannot be changed.' using errcode='22023';end if;
  if not exists(select 1 from public.ugc_characters where id=p_character_id and is_active) then raise exception 'That creator is no longer available.' using errcode='22023';end if;
  update public.content_items set selected_ugc_character_id=p_character_id,ugc_character_selection_confirmed=true where id=v_item.id returning * into v_item;return v_item;
end;$$;

create or replace function public.edit_content_plan_item(p_content_item_id uuid,p_expected_revision integer,p_platform_targets public.social_platform[],p_format public.content_format,p_working_title text,p_hook text,p_concept text,p_creative_direction text,p_call_to_action text,p_creative_mode text,p_selected_product_id uuid,p_product_selection_confirmed boolean,p_selected_ugc_character_id uuid,p_ugc_character_selection_confirmed boolean) returns public.content_items
language plpgsql security definer set search_path='' as $$ declare v_item public.content_items; begin
  select * into v_item from public.content_items where id=p_content_item_id for update;
  if v_item.id is null or not public.is_organization_member(v_item.organization_id) then raise exception 'Content item unavailable' using errcode='42501';end if;
  if v_item.content_revision<>p_expected_revision then raise exception 'Content item changed' using errcode='40001';end if;
  if v_item.status not in ('draft_plan','planned') then raise exception 'Only planned creatives can be edited.' using errcode='22023';end if;
  if coalesce(cardinality(p_platform_targets),0)=0 or coalesce(length(btrim(p_working_title)),0)=0 or coalesce(length(btrim(p_concept)),0)=0 then raise exception 'Add a title, a concept, and at least one destination.' using errcode='22023';end if;
  if p_creative_mode not in ('standard','product','ugc','product_ugc') or (p_creative_mode='product' and p_format not in ('image','short_video')) or (p_creative_mode in ('ugc','product_ugc') and p_format<>'short_video') then raise exception 'Choose a valid creative type.' using errcode='22023';end if;
  if p_creative_mode in ('product','product_ugc') and p_selected_product_id is not null and not exists(select 1 from public.products p where p.id=p_selected_product_id and p.organization_id=v_item.organization_id and p.brand_id=v_item.brand_id and p.is_active) then raise exception 'That product is no longer available.' using errcode='22023';end if;
  if p_creative_mode in ('ugc','product_ugc') and p_selected_ugc_character_id is not null and not exists(select 1 from public.ugc_characters c where c.id=p_selected_ugc_character_id and c.is_active) then raise exception 'That creator is no longer available.' using errcode='22023';end if;
  update public.content_items set platform_targets=p_platform_targets,format=p_format,working_title=btrim(p_working_title),hook=nullif(btrim(p_hook),''),concept=btrim(p_concept),creative_direction=nullif(btrim(p_creative_direction),''),call_to_action=nullif(btrim(p_call_to_action),''),creative_mode=p_creative_mode,
    selected_product_id=case when p_creative_mode in ('product','product_ugc') then p_selected_product_id else null end,product_selection_confirmed=case when p_creative_mode in ('product','product_ugc') then coalesce(p_product_selection_confirmed,false) else false end,
    selected_ugc_character_id=case when p_creative_mode in ('ugc','product_ugc') then p_selected_ugc_character_id else null end,ugc_character_selection_confirmed=case when p_creative_mode in ('ugc','product_ugc') then coalesce(p_ugc_character_selection_confirmed,false) else false end where id=v_item.id returning * into v_item;return v_item;
end;$$;
