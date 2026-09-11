-- T22: recommendation decisions are one-way, attributed, and tenant scoped.

create table public.account_metric_snapshots (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  social_connection_id uuid not null,
  captured_for date not null,
  reach bigint check (reach is null or reach >= 0),
  profile_visits bigint check (profile_visits is null or profile_visits >= 0),
  follower_count bigint check (follower_count is null or follower_count >= 0),
  audience_demographics jsonb,
  online_followers jsonb,
  raw_metrics jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  foreign key (social_connection_id,organization_id) references public.social_connections(id,organization_id) on delete cascade,
  unique (social_connection_id,captured_for),
  unique (id,organization_id)
);

alter table public.account_metric_snapshots enable row level security;
create policy "Organization members can view account metric snapshots" on public.account_metric_snapshots
  for select to authenticated using ((select public.is_organization_member(organization_id)));
grant select on public.account_metric_snapshots to authenticated;

drop policy if exists "Organization members can respond to recommendations" on public.recommendations;
revoke update on public.recommendations from authenticated;

create or replace function public.respond_to_performance_recommendation(
  p_recommendation_id uuid,
  p_response public.recommendation_status
)
returns public.recommendations
language plpgsql
security definer
set search_path = ''
as $function$
declare
  result public.recommendations;
begin
  if p_response not in ('accepted', 'ignored') then
    raise exception 'Recommendation response must be accepted or ignored' using errcode = '22023';
  end if;

  update public.recommendations recommendation
  set status = p_response,
      responded_by = (select auth.uid()),
      responded_at = now()
  where recommendation.id = p_recommendation_id
    and recommendation.status = 'pending'
    and (select public.is_organization_member(recommendation.organization_id))
  returning recommendation.* into result;

  if result.id is null then
    raise exception 'Recommendation is unavailable or already answered' using errcode = 'P0002';
  end if;
  return result;
end;
$function$;

revoke all on function public.respond_to_performance_recommendation(uuid,public.recommendation_status) from public,anon;
grant execute on function public.respond_to_performance_recommendation(uuid,public.recommendation_status) to authenticated;

select cron.unschedule('rithena-analytics-worker') where exists(select 1 from cron.job where jobname='rithena-analytics-worker');
select cron.schedule('rithena-analytics-worker','0 5 * * *',$worker$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name='rithena_analytics_worker_url' order by created_at desc limit 1),
    headers := jsonb_build_object('Authorization','Bearer '||(select decrypted_secret from vault.decrypted_secrets where name='rithena_cron_secret' order by created_at desc limit 1),'Content-Type','application/json'),
    body := '{}'::jsonb,
    timeout_milliseconds := 150000
  );
$worker$);
