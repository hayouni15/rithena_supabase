-- Make a disconnected Facebook Page reconnect as a fresh destination while
-- preserving historical schedules, posts, and analytics attached to the old row.

create or replace function public.archive_disconnected_facebook_identity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.platform = 'facebook'
    and new.last_error_code = 'disconnected'
    and new.provider_account_id not like 'disconnected:%'
  then
    update public.social_connections
    set provider_account_id = 'disconnected:' || new.id::text || ':' || new.provider_account_id,
        metadata = coalesce(new.metadata, '{}'::jsonb)
          || jsonb_build_object('disconnectedProviderAccountId', new.provider_account_id)
    where id = new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists archive_disconnected_facebook_identity on public.social_connections;
create trigger archive_disconnected_facebook_identity
after insert or update of last_error_code on public.social_connections
for each row execute function public.archive_disconnected_facebook_identity();

-- Normalize Facebook rows disconnected before this migration.
update public.social_connections
set provider_account_id = 'disconnected:' || id::text || ':' || provider_account_id,
    metadata = coalesce(metadata, '{}'::jsonb)
      || jsonb_build_object('disconnectedProviderAccountId', provider_account_id)
where platform = 'facebook'
  and last_error_code = 'disconnected'
  and provider_account_id not like 'disconnected:%';

revoke all on function public.archive_disconnected_facebook_identity() from public, anon, authenticated;
