-- Allow approved, unchanged creatives to reach remaining destinations after publication.
create or replace function public.guard_schedule() returns trigger
language plpgsql set search_path = '' as $$
declare item public.content_items; variant public.platform_variants;
begin
  select * into item from public.content_items where id = new.content_item_id;
  select * into variant from public.platform_variants where id = new.platform_variant_id;
  if item.id is null or variant.id is null
    or item.organization_id <> new.organization_id
    or variant.organization_id <> new.organization_id
    or variant.content_item_id <> item.id then
    raise exception 'Schedule resources do not belong to the same content item' using errcode = '23503';
  end if;
  if new.status = 'scheduled' and (
    item.status not in ('approved', 'scheduled', 'publishing', 'published')
    or new.content_revision <> item.content_revision
    or not exists (
      select 1 from public.approvals a where a.content_item_id = item.id
        and a.content_revision = item.content_revision and a.decision = 'approved'
    )
  ) then
    raise exception 'Current content revision is not approved' using errcode = '22023';
  end if;
  return new;
end;
$$;

