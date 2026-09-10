-- Follow-up kept separate so environments that already applied the base email milestone
-- also receive connected/disconnected events safely.

alter table public.email_deliveries drop constraint if exists email_deliveries_event_type_check;
alter table public.email_deliveries add constraint email_deliveries_event_type_check
  check(event_type in ('welcome','first_week_ready','content_ready','content_published','generation_failed','publishing_failed','connection_connected','connection_disconnected','connection_expired'));

create or replace function public.enqueue_organization_email(
  p_organization_id uuid,p_content_item_id uuid,p_event_type text,p_event_key text,p_payload jsonb,p_user_id uuid default null
) returns void language plpgsql security definer set search_path='' as $$
begin
  if p_event_type not in ('welcome','first_week_ready','content_ready','content_published','generation_failed','publishing_failed','connection_connected','connection_disconnected','connection_expired') then
    raise exception 'Invalid email event' using errcode='22023';
  end if;
  insert into public.email_deliveries(organization_id,user_id,content_item_id,event_type,event_key,payload)
  select p_organization_id,m.user_id,p_content_item_id,p_event_type,p_event_key,coalesce(p_payload,'{}'::jsonb)
  from public.organization_members m where m.organization_id=p_organization_id and (p_user_id is null or m.user_id=p_user_id)
  on conflict(user_id,event_key) do nothing;
end;
$$;

create or replace function public.enqueue_instagram_connection_email() returns trigger language plpgsql security definer set search_path='' as $$
declare event_name text; event_stamp text;
begin
  if new.platform<>'instagram' then return new; end if;
  event_stamp:=to_char(new.updated_at at time zone 'UTC','YYYYMMDDHH24MISSMS');
  if new.status='connected' and (tg_op='INSERT' or old.status is distinct from 'connected') then
    event_name:='connection_connected';
    perform public.enqueue_organization_email(new.organization_id,null,event_name,event_name||':'||new.id::text||':'||event_stamp,
      jsonb_build_object('handle',new.provider_account_handle,'actionUrl','/connections'));
  elsif tg_op='UPDATE' and new.status='revoked' and new.last_error_code='disconnected'
    and (old.status is distinct from 'revoked' or old.last_error_code is distinct from 'disconnected') then
    event_name:='connection_disconnected';
    perform public.enqueue_organization_email(new.organization_id,null,event_name,event_name||':'||new.id::text||':'||event_stamp,
      jsonb_build_object('handle',new.provider_account_handle,'actionUrl','/connections'));
  end if;
  return new;
end;
$$;

drop trigger if exists enqueue_instagram_connection_email on public.social_connections;
create trigger enqueue_instagram_connection_email after insert or update of status,last_error_code on public.social_connections
for each row execute function public.enqueue_instagram_connection_email();

revoke all on function public.enqueue_organization_email(uuid,uuid,text,text,jsonb,uuid) from public,anon,authenticated;
revoke all on function public.enqueue_instagram_connection_email() from public,anon,authenticated;
