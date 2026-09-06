-- Existing environments received the lifecycle foundation before the insert guard was added.
-- Keep this follow-up idempotent so new and already-migrated databases enforce the same rule.

create or replace function public.guard_content_item_insert() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.status <> 'draft_plan' then
    raise exception 'New content items must begin as draft plans' using errcode = '22023';
  end if;
  return new;
end;
$$;

drop trigger if exists guard_content_item_insert on public.content_items;
create trigger guard_content_item_insert
before insert on public.content_items
for each row execute function public.guard_content_item_insert();
