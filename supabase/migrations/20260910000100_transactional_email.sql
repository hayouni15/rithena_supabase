-- Transactional email outbox for milestone 4.5. Provider calls remain server-side.

create table public.email_deliveries(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  content_item_id uuid references public.content_items(id) on delete cascade,
  event_type text not null check(event_type in ('welcome','first_week_ready','content_ready','content_published','generation_failed','publishing_failed','connection_connected','connection_disconnected','connection_expired')),
  event_key text not null,
  payload jsonb not null default '{}'::jsonb check(jsonb_typeof(payload)='object'),
  state text not null default 'queued' check(state in ('queued','sending','sent','delivered','failed','bounced','complained')),
  attempt integer not null default 0 check(attempt>=0),
  max_attempts integer not null default 5 check(max_attempts between 1 and 10),
  next_attempt_at timestamptz not null default now(),
  lease_owner text,
  lease_expires_at timestamptz,
  provider_message_id text unique,
  last_error text,
  sent_at timestamptz,
  delivered_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id,event_key),
  check((lease_owner is null)=(lease_expires_at is null))
);
create index email_deliveries_due_idx on public.email_deliveries(state,next_attempt_at) where state in ('queued','sending');
create trigger set_email_deliveries_updated_at before update on public.email_deliveries for each row execute function public.set_updated_at();
alter table public.email_deliveries enable row level security;
create policy "Users can view their email deliveries" on public.email_deliveries for select to authenticated using(user_id=(select auth.uid()));
grant select on public.email_deliveries to authenticated;
grant all on public.email_deliveries to service_role;

create table public.email_webhook_events(
  id text primary key,
  event_type text not null,
  provider_message_id text,
  received_at timestamptz not null default now()
);
alter table public.email_webhook_events enable row level security;
grant all on public.email_webhook_events to service_role;

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

create or replace function public.enqueue_email_from_notification() returns trigger language plpgsql security definer set search_path='' as $$
declare mapped text;
begin
  if new.type::text='connection_expired' and exists(
    select 1 from public.social_connections where organization_id=new.organization_id and platform='instagram'
      and status='revoked' and last_error_code='disconnected' and updated_at>now()-interval '1 minute'
  ) then return new; end if;
  if new.type::text='publishing_failed' and new.event_key is null and exists(
    select 1 from public.email_deliveries where organization_id=new.organization_id and content_item_id=new.content_item_id
      and event_type='publishing_failed' and created_at>now()-interval '1 minute'
  ) then return new; end if;
  mapped:=case new.type::text when 'first_week_ready' then 'first_week_ready' when 'approval_needed' then 'content_ready'
    when 'generation_failed' then 'generation_failed' when 'publishing_failed' then 'publishing_failed'
    when 'connection_expired' then 'connection_expired' else null end;
  if mapped is not null then
    perform public.enqueue_organization_email(new.organization_id,new.content_item_id,mapped,
      'notification:'||coalesce(new.event_key,new.id::text),
      jsonb_build_object('title',new.title,'message',new.message,'actionUrl',new.action_url,
        'contentTitle',(select working_title from public.content_items where id=new.content_item_id),
        'format',(select format::text from public.content_items where id=new.content_item_id)),new.user_id);
  end if;
  return new;
end;
$$;
create trigger enqueue_notification_email after insert on public.notifications for each row execute function public.enqueue_email_from_notification();

create or replace function public.enqueue_welcome_email() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if old.onboarding_completed_at is null and new.onboarding_completed_at is not null then
    perform public.enqueue_organization_email(new.organization_id,null,'welcome','welcome:'||new.id::text,
      jsonb_build_object('brandName',new.name,'actionUrl','/home'),new.created_by);
  end if;
  return new;
end;
$$;
create trigger enqueue_welcome_email after update of onboarding_completed_at on public.brands for each row execute function public.enqueue_welcome_email();

create or replace function public.enqueue_published_email() returns trigger language plpgsql security definer set search_path='' as $$
declare item public.content_items;
begin
  select * into item from public.content_items where id=new.content_item_id;
  perform public.enqueue_organization_email(new.organization_id,new.content_item_id,'content_published','published:'||new.id::text,
    jsonb_build_object('title',item.working_title,'platform','Instagram','publishedAt',new.published_at,'remotePostUrl',new.remote_post_url,'actionUrl','/content/'||new.content_item_id::text));
  return new;
end;
$$;
create trigger enqueue_content_published_email after insert on public.published_posts for each row execute function public.enqueue_published_email();

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
create trigger enqueue_instagram_connection_email after insert or update of status,last_error_code on public.social_connections for each row execute function public.enqueue_instagram_connection_email();

create or replace function public.claim_email_deliveries(p_worker_id text,p_limit integer default 10)
returns setof public.email_deliveries language plpgsql security definer set search_path='' as $$
begin
  if auth.role()<>'service_role' or coalesce(length(btrim(p_worker_id)),0)<8 or p_limit not between 1 and 25 then raise exception 'Email worker unavailable' using errcode='42501'; end if;
  return query update public.email_deliveries d set state='sending',attempt=d.attempt+1,lease_owner=p_worker_id,lease_expires_at=now()+interval '3 minutes'
  where d.id in (select x.id from public.email_deliveries x where x.attempt<x.max_attempts and x.next_attempt_at<=now()
    and (x.state='queued' or (x.state='sending' and x.lease_expires_at<now())) order by x.created_at for update skip locked limit p_limit)
  returning d.*;
end;
$$;

create or replace function public.checkpoint_email_delivery(p_id uuid,p_worker_id text,p_provider_message_id text,p_error text)
returns void language plpgsql security definer set search_path='' as $$
declare delivery public.email_deliveries;
begin
  if auth.role()<>'service_role' then raise exception 'Email worker unavailable' using errcode='42501'; end if;
  select * into delivery from public.email_deliveries where id=p_id for update;
  if delivery.id is null or delivery.state<>'sending' or delivery.lease_owner is distinct from p_worker_id then raise exception 'Email lease unavailable' using errcode='42501'; end if;
  if p_provider_message_id is not null then
    update public.email_deliveries set state='sent',provider_message_id=p_provider_message_id,last_error=null,sent_at=now(),lease_owner=null,lease_expires_at=null where id=p_id;
  elsif delivery.attempt>=delivery.max_attempts then
    update public.email_deliveries set state='failed',last_error=left(coalesce(p_error,'Email provider rejected the request.'),500),lease_owner=null,lease_expires_at=null where id=p_id;
  else
    update public.email_deliveries set state='queued',last_error=left(coalesce(p_error,'Email delivery failed.'),500),next_attempt_at=now()+make_interval(mins=>least(60,power(2,delivery.attempt)::integer)),lease_owner=null,lease_expires_at=null where id=p_id;
  end if;
end;
$$;

create or replace function public.record_resend_webhook(p_event_id text,p_event_type text,p_provider_message_id text,p_created_at timestamptz)
returns void language plpgsql security definer set search_path='' as $$
declare inserted boolean;
begin
  if auth.role()<>'service_role' or coalesce(length(p_event_id),0)=0 or coalesce(length(p_provider_message_id),0)=0 then raise exception 'Email webhook unavailable' using errcode='42501'; end if;
  insert into public.email_webhook_events(id,event_type,provider_message_id) values(p_event_id,p_event_type,p_provider_message_id)
  on conflict(id) do nothing returning true into inserted;
  if not coalesce(inserted,false) then return; end if;
  if p_event_type='email.complained' then
    update public.email_deliveries set state='complained',last_error='Resend reported email.complained.' where provider_message_id=p_provider_message_id;
  elsif p_event_type='email.bounced' then
    update public.email_deliveries set state='bounced',last_error='Resend reported email.bounced.' where provider_message_id=p_provider_message_id and state<>'complained';
  elsif p_event_type in ('email.failed','email.suppressed') then
    update public.email_deliveries set state='failed',last_error='Resend reported '||p_event_type||'.' where provider_message_id=p_provider_message_id and state not in ('bounced','complained','delivered');
  elsif p_event_type='email.delivered' then
    update public.email_deliveries set state='delivered',delivered_at=p_created_at,last_error=null where provider_message_id=p_provider_message_id and state in ('sending','sent');
  end if;
end;
$$;

revoke all on function public.enqueue_organization_email(uuid,uuid,text,text,jsonb,uuid) from public,anon,authenticated;
revoke all on function public.enqueue_email_from_notification() from public,anon,authenticated;
revoke all on function public.enqueue_welcome_email() from public,anon,authenticated;
revoke all on function public.enqueue_published_email() from public,anon,authenticated;
revoke all on function public.enqueue_instagram_connection_email() from public,anon,authenticated;
revoke all on function public.claim_email_deliveries(text,integer) from public,anon,authenticated;
revoke all on function public.checkpoint_email_delivery(uuid,text,text,text) from public,anon,authenticated;
revoke all on function public.record_resend_webhook(text,text,text,timestamptz) from public,anon,authenticated;
grant execute on function public.claim_email_deliveries(text,integer) to service_role;
grant execute on function public.checkpoint_email_delivery(uuid,text,text,text) to service_role;
grant execute on function public.record_resend_webhook(text,text,text,timestamptz) to service_role;
