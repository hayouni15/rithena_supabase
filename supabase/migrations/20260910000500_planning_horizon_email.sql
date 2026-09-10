-- Announce the full configured planning horizon only after every week exists.

create or replace function public.create_first_week_notification() returns trigger
language plpgsql security definer set search_path='' as $$
declare
  horizon integer;
  cycle_start date;
  ready_count integer;
  first_plan_id uuid;
  title_text text;
  message_text text;
begin
  if new.status<>'ready' or new.version<>1 then return new; end if;

  select planning_horizon_weeks into horizon
  from public.brands where id=new.brand_id;
  horizon:=greatest(1,least(4,coalesce(horizon,1)));
  cycle_start:=new.starts_on-((horizon-1)*7);

  select count(*) into ready_count
  from public.content_plans
  where brand_id=new.brand_id and version=1 and status='ready'
    and starts_on between cycle_start and new.starts_on
    and mod(new.starts_on-starts_on,7)=0;

  if ready_count<>horizon then return new; end if;

  select id into first_plan_id from public.content_plans
  where brand_id=new.brand_id and version=1 and status='ready' and starts_on=cycle_start
  order by created_at limit 1;
  if first_plan_id is null then return new; end if;

  if horizon=1 then
    title_text:='Your first content week is ready';
    message_text:='Your first week has a clear direction.';
  else
    title_text:='Your first '||horizon::text||' content weeks are ready';
    message_text:='Your first '||horizon::text||' weeks have a clear direction.';
  end if;

  perform public.notify_organization_members(
    new.organization_id,null,'first_week_ready',title_text,message_text,
    '/calendar?plan='||first_plan_id::text,
    'first-week:'||new.brand_id::text,
    new.created_by
  );
  return new;
end;
$$;

revoke all on function public.create_first_week_notification() from public,anon,authenticated;
