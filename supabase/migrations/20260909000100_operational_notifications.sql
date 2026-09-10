-- Actionable, user-scoped operational notifications with durable deduplication.

alter table public.notifications add column event_key text;

create unique index notifications_user_event_key_idx
  on public.notifications(user_id,event_key)
  where event_key is not null;

create or replace function public.notify_organization_members(
  p_organization_id uuid,
  p_content_item_id uuid,
  p_type public.notification_type,
  p_title text,
  p_message text,
  p_action_url text,
  p_event_key text,
  p_user_id uuid default null
) returns void
language plpgsql security definer set search_path='' as $$
begin
  insert into public.notifications(
    organization_id,user_id,content_item_id,type,title,message,action_url,event_key
  )
  select p_organization_id,m.user_id,p_content_item_id,p_type,p_title,p_message,p_action_url,p_event_key
  from public.organization_members m
  where m.organization_id=p_organization_id
    and (p_user_id is null or m.user_id=p_user_id)
  on conflict(user_id,event_key) where event_key is not null do nothing;
end;
$$;

create or replace function public.create_content_review_notification() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.status='ready_for_review' and old.status is distinct from new.status then
    perform public.notify_organization_members(
      new.organization_id,new.id,'approval_needed','A post is ready for review',
      coalesce(nullif(btrim(new.working_title),''),'Your generated post')||' is ready for your approval.',
      '/content/'||new.id::text,
      'approval:'||new.id::text||':revision:'||new.content_revision::text
    );
  end if;
  return new;
end;
$$;

create trigger notify_content_ready_for_review
after update of status on public.content_items
for each row execute function public.create_content_review_notification();

create or replace function public.create_first_week_notification() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.status='ready' and new.version=1 then
    perform public.notify_organization_members(
      new.organization_id,null,'first_week_ready','Your first content week is ready',
      'Review the plan, adjust its timing, then start creative production.',
      '/calendar?plan='||new.id::text,
      'first-week:'||new.brand_id::text,
      new.created_by
    );
  end if;
  return new;
end;
$$;

create trigger notify_first_week_ready
after insert on public.content_plans
for each row execute function public.create_first_week_notification();

create or replace function public.create_generation_failure_notification() returns trigger
language plpgsql security definer set search_path='' as $$
declare item_title text;
begin
  if new.state='failed' and old.state is distinct from new.state then
    select working_title into item_title from public.content_items where id=new.content_item_id;
    perform public.notify_organization_members(
      new.organization_id,new.content_item_id,'generation_failed','Creative production needs attention',
      coalesce(nullif(btrim(item_title),''),'A creative')||' could not be completed. Open it to retry production.',
      case when new.content_item_id is null then '/calendar' else '/content/'||new.content_item_id::text end,
      'generation-failed:'||new.id::text
    );
  end if;
  return new;
end;
$$;

create trigger notify_generation_failed
after update of state on public.generation_jobs
for each row execute function public.create_generation_failure_notification();

create or replace function public.create_connection_notification() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.status in ('expired','revoked') and old.status is distinct from new.status then
    perform public.notify_organization_members(
      new.organization_id,null,'connection_expired','Reconnect Instagram',
      'Instagram access is no longer valid. Reconnect it before the next scheduled post.',
      '/connections',
      'connection:'||new.id::text||':'||new.status::text||':'||to_char(current_date,'YYYY-MM-DD')
    );
  end if;
  return new;
end;
$$;

create trigger notify_connection_expired
after update of status on public.social_connections
for each row execute function public.create_connection_notification();

create or replace function public.create_exhausted_publish_notification() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.state='failed' and old.state is distinct from new.state and new.error_code='attempts_exhausted' then
    perform public.notify_organization_members(
      new.organization_id,new.content_item_id,'publishing_failed','Instagram publishing needs attention',
      'Publishing attempts were exhausted. Open the post to review and reschedule it.',
      '/content/'||new.content_item_id::text,
      'publishing-failed:'||new.id::text
    );
  end if;
  return new;
end;
$$;

create trigger notify_exhausted_publish_job
after update of state on public.publish_jobs
for each row execute function public.create_exhausted_publish_notification();

revoke all on function public.notify_organization_members(uuid,uuid,public.notification_type,text,text,text,text,uuid) from public,anon,authenticated;
revoke all on function public.create_content_review_notification() from public,anon,authenticated;
revoke all on function public.create_first_week_notification() from public,anon,authenticated;
revoke all on function public.create_generation_failure_notification() from public,anon,authenticated;
revoke all on function public.create_connection_notification() from public,anon,authenticated;
revoke all on function public.create_exhausted_publish_notification() from public,anon,authenticated;

