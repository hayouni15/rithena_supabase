-- Full video regeneration consumes one regeneration credit. Composition-only
-- re-renders remain free because they do not call this function.

create or replace function public.request_unpublished_content_regeneration(
  p_content_item_id uuid,p_expected_revision integer,p_direction text,p_provider text,p_model text,p_input jsonb,p_mode text
) returns public.content_items language plpgsql security definer set search_path='' as $$
declare item public.content_items; charge integer;
begin
  item := public.prepare_unpublished_content_edit(p_content_item_id,p_expected_revision);
  charge := case
    when p_mode<>'media' then 0
    when item.format='carousel' then 4
    when item.format in ('image','short_video') then 1
    else 0
  end;
  if charge>0 then perform public.consume_regeneration_credits(item.organization_id,item.brand_id,item.id,charge,'creative',item.id||':'||(p_expected_revision+1)::text||':creative'); end if;
  return public.request_content_regeneration(p_content_item_id,p_expected_revision,p_direction,p_provider,p_model,p_input,p_mode);
end;
$$;

revoke all on function public.request_unpublished_content_regeneration(uuid,integer,text,text,text,jsonb,text) from public,anon,authenticated;
grant execute on function public.request_unpublished_content_regeneration(uuid,integer,text,text,text,jsonb,text) to authenticated;
