-- T18 correction: 008 was deployed before selectable plans were added to its local source.
-- Keep this as a new immutable migration so production receives the catalog and functions.

alter table public.subscriptions alter column trial_ends_at drop default;
update public.subscriptions set plan_code='free_trial',trial_ends_at=null where plan_code='trial';

create table if not exists public.billing_plans (
  code text primary key,
  name text not null,
  monthly_price_usd numeric(8,2) not null check(monthly_price_usd>=0),
  creative_limit integer check(creative_limit is null or creative_limit>0),
  sort_order integer not null unique,
  is_selectable boolean not null default true
);
insert into public.billing_plans(code,name,monthly_price_usd,creative_limit,sort_order) values
  ('free_trial','Free Trial',0,1,0),('byok','BYOK',19,null,1),('managed','Managed',49,null,2),('growth','Growth',89,null,3)
on conflict(code) do update set name=excluded.name,monthly_price_usd=excluded.monthly_price_usd,creative_limit=excluded.creative_limit,sort_order=excluded.sort_order,is_selectable=true;
alter table public.billing_plans enable row level security;
drop policy if exists "Anyone can view billing plans" on public.billing_plans;
create policy "Anyone can view billing plans" on public.billing_plans for select to authenticated using(true);
grant select on public.billing_plans to authenticated;
grant all on public.billing_plans to service_role;
revoke all on public.billing_plans from anon;

create or replace function public.handle_new_organization_subscription()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  insert into public.subscriptions(organization_id,plan_code,status,trial_started_at,trial_ends_at)
  values(new.id,'free_trial','trialing',now(),null) on conflict(organization_id) do nothing;
  return new;
end;
$$;

create or replace function public.enforce_creative_allowance()
returns trigger language plpgsql security definer set search_path='' as $$
declare subscription public.subscriptions; used_count integer;
begin
  if new.type not in ('image','video') then return new; end if;
  perform pg_advisory_xact_lock(hashtextextended(new.organization_id::text,180018));
  select * into subscription from public.subscriptions where organization_id=new.organization_id for update;
  if subscription.id is null then raise exception 'A billing subscription is required' using errcode='P0001'; end if;
  if subscription.status not in ('trialing','active') then raise exception 'Your subscription does not currently allow creative production' using errcode='P0001'; end if;
  if subscription.plan_code='free_trial' then
    select count(*) into used_count from public.generation_jobs where organization_id=new.organization_id and type in ('image','video') and state<>'cancelled';
    if used_count>=1 then raise exception 'Your free creative preview has already been used' using errcode='P0001'; end if;
  end if;
  return new;
end;
$$;

create or replace function public.get_billing_summary(p_organization_id uuid)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare subscription public.subscriptions; selected_plan public.billing_plans; preview_used integer; month_start timestamptz; month_end timestamptz; usage jsonb; plans jsonb;
begin
  if not public.is_organization_member(p_organization_id) then raise exception 'Organization unavailable' using errcode='42501'; end if;
  select * into subscription from public.subscriptions where organization_id=p_organization_id;
  if subscription.id is null then raise exception 'Subscription unavailable' using errcode='P0001'; end if;
  select * into selected_plan from public.billing_plans where code=subscription.plan_code;
  select count(*) into preview_used from public.generation_jobs where organization_id=p_organization_id and type in ('image','video') and state<>'cancelled';
  month_start:=date_trunc('month',now()); month_end:=month_start+interval '1 month';
  select coalesce(jsonb_agg(row_data order by event_type),'[]'::jsonb) into usage from (
    select event_type,unit,sum(quantity) quantity,sum(cost) filter(where cost is not null) cost from public.usage_events
    where organization_id=p_organization_id and occurred_at>=month_start and occurred_at<month_end group by event_type,unit
  ) row_data;
  select jsonb_agg(jsonb_build_object('code',code,'name',name,'monthlyPriceUsd',monthly_price_usd,'creativeLimit',creative_limit) order by sort_order)
    into plans from public.billing_plans where is_selectable;
  return jsonb_build_object('planCode',subscription.plan_code,'planName',selected_plan.name,'monthlyPriceUsd',selected_plan.monthly_price_usd,'plans',plans,
    'status',subscription.status,'trialStartedAt',subscription.trial_started_at,'trialEndsAt',subscription.trial_ends_at,
    'currentPeriodStartedAt',subscription.current_period_started_at,'currentPeriodEndsAt',subscription.current_period_ends_at,
    'cancelAtPeriodEnd',subscription.cancel_at_period_end,'creativePreviewLimit',selected_plan.creative_limit,'creativePreviewUsed',preview_used,
    'canCreate',subscription.status in ('trialing','active') and (selected_plan.creative_limit is null or preview_used<selected_plan.creative_limit),
    'monthStartedAt',month_start,'usage',usage);
end;
$$;

create or replace function public.select_subscription_plan(p_organization_id uuid,p_plan_code text)
returns public.subscriptions language plpgsql security definer set search_path='' as $$
declare result public.subscriptions;
begin
  if not public.has_organization_role(p_organization_id,array['owner','admin']::public.organization_role[]) then raise exception 'Organization unavailable' using errcode='42501'; end if;
  if not exists(select 1 from public.billing_plans where code=p_plan_code and is_selectable) then raise exception 'Plan unavailable' using errcode='22023'; end if;
  update public.subscriptions set plan_code=p_plan_code,status=case when p_plan_code='free_trial' then 'trialing'::public.subscription_status else 'active'::public.subscription_status end,
    provider='manual',provider_customer_id=null,provider_subscription_id=null,trial_ends_at=null,
    current_period_started_at=case when p_plan_code='free_trial' then null else now() end,
    current_period_ends_at=case when p_plan_code='free_trial' then null else now()+interval '1 month' end,
    cancel_at_period_end=false,cancelled_at=null where organization_id=p_organization_id returning * into result;
  return result;
end;
$$;

revoke all on function public.select_subscription_plan(uuid,text) from public,anon;
grant execute on function public.select_subscription_plan(uuid,text) to authenticated;
