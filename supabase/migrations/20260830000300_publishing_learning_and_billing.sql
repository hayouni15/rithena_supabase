-- Scheduling, reliable publishing, analytics, learning, usage, and billing.

create type public.job_state as enum (
  'queued',
  'running',
  'waiting_external',
  'retrying',
  'succeeded',
  'failed',
  'cancelled'
);

create type public.schedule_status as enum (
  'draft',
  'scheduled',
  'cancelled',
  'completed',
  'failed'
);

create type public.generation_job_type as enum (
  'plan',
  'copy',
  'image',
  'video',
  'render',
  'qa'
);

create type public.learning_signal_type as enum (
  'approved_unchanged',
  'edited',
  'rejected',
  'regenerated',
  'performance',
  'user_preference'
);

create type public.recommendation_status as enum (
  'pending',
  'accepted',
  'ignored',
  'superseded'
);

create type public.subscription_status as enum (
  'trialing',
  'active',
  'past_due',
  'paused',
  'cancelled',
  'incomplete'
);

create type public.notification_type as enum (
  'approval_needed',
  'publishing_failed',
  'connection_expired',
  'first_week_ready',
  'strategy_recommendation',
  'generation_failed'
);

create table public.schedules (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  content_item_id uuid not null,
  platform_variant_id uuid not null,
  social_connection_id uuid not null,
  scheduled_for timestamptz not null,
  timezone text not null,
  status public.schedule_status not null default 'scheduled',
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (content_item_id, organization_id)
    references public.content_items (id, organization_id) on delete cascade,
  foreign key (platform_variant_id, organization_id)
    references public.platform_variants (id, organization_id) on delete cascade,
  foreign key (social_connection_id, organization_id)
    references public.social_connections (id, organization_id) on delete cascade,
  unique (id, organization_id)
);

create table public.publish_jobs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  schedule_id uuid not null,
  content_item_id uuid not null,
  platform_variant_id uuid not null,
  social_connection_id uuid not null,
  state public.job_state not null default 'queued',
  idempotency_key text not null unique,
  provider_job_id text,
  attempt integer not null default 0 check (attempt >= 0),
  max_attempts integer not null default 3 check (max_attempts > 0),
  next_attempt_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  error_code text,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (schedule_id, organization_id)
    references public.schedules (id, organization_id) on delete cascade,
  foreign key (content_item_id, organization_id)
    references public.content_items (id, organization_id) on delete cascade,
  foreign key (platform_variant_id, organization_id)
    references public.platform_variants (id, organization_id) on delete cascade,
  foreign key (social_connection_id, organization_id)
    references public.social_connections (id, organization_id) on delete cascade,
  unique (id, organization_id)
);

comment on column public.publish_jobs.idempotency_key is
  'Unique operation key preventing duplicate remote posts across retries.';

create table public.publish_attempts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  publish_job_id uuid not null,
  attempt_number integer not null check (attempt_number > 0),
  state public.job_state not null,
  request_summary jsonb not null default '{}'::jsonb,
  response_summary jsonb not null default '{}'::jsonb,
  error_code text,
  error_message text,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  foreign key (publish_job_id, organization_id)
    references public.publish_jobs (id, organization_id) on delete cascade,
  unique (publish_job_id, attempt_number),
  unique (id, organization_id)
);

create table public.published_posts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  publish_job_id uuid not null,
  content_item_id uuid not null,
  platform_variant_id uuid not null,
  social_connection_id uuid not null,
  remote_post_id text not null,
  remote_post_url text,
  published_at timestamptz not null,
  provider_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (publish_job_id, organization_id)
    references public.publish_jobs (id, organization_id) on delete cascade,
  foreign key (content_item_id, organization_id)
    references public.content_items (id, organization_id) on delete cascade,
  foreign key (platform_variant_id, organization_id)
    references public.platform_variants (id, organization_id) on delete cascade,
  foreign key (social_connection_id, organization_id)
    references public.social_connections (id, organization_id) on delete cascade,
  unique (publish_job_id),
  unique (social_connection_id, remote_post_id),
  unique (id, organization_id)
);

create table public.metric_snapshots (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  published_post_id uuid not null,
  captured_at timestamptz not null,
  reach bigint check (reach is null or reach >= 0),
  impressions bigint check (impressions is null or impressions >= 0),
  views bigint check (views is null or views >= 0),
  watch_time_seconds numeric(16, 3) check (watch_time_seconds is null or watch_time_seconds >= 0),
  average_view_duration_seconds numeric(12, 3)
    check (average_view_duration_seconds is null or average_view_duration_seconds >= 0),
  retention_rate numeric(6, 5) check (retention_rate is null or retention_rate between 0 and 1),
  likes bigint check (likes is null or likes >= 0),
  comments bigint check (comments is null or comments >= 0),
  saves bigint check (saves is null or saves >= 0),
  shares bigint check (shares is null or shares >= 0),
  profile_visits bigint check (profile_visits is null or profile_visits >= 0),
  clicks bigint check (clicks is null or clicks >= 0),
  conversions bigint check (conversions is null or conversions >= 0),
  raw_metrics jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  foreign key (published_post_id, organization_id)
    references public.published_posts (id, organization_id) on delete cascade,
  unique (published_post_id, captured_at),
  unique (id, organization_id)
);

create table public.generation_jobs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  brand_id uuid,
  content_item_id uuid,
  type public.generation_job_type not null,
  state public.job_state not null default 'queued',
  provider text not null,
  model text,
  external_job_id text,
  attempt integer not null default 0 check (attempt >= 0),
  max_attempts integer not null default 3 check (max_attempts > 0),
  input jsonb not null default '{}'::jsonb,
  output jsonb not null default '{}'::jsonb,
  cost_estimate numeric(12, 6) check (cost_estimate is null or cost_estimate >= 0),
  actual_cost numeric(12, 6) check (actual_cost is null or actual_cost >= 0),
  error_code text,
  error_message text,
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (brand_id, organization_id)
    references public.brands (id, organization_id)
    on delete set null (brand_id),
  foreign key (content_item_id, organization_id)
    references public.content_items (id, organization_id)
    on delete set null (content_item_id),
  unique (id, organization_id)
);

create table public.learning_signals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  brand_id uuid not null,
  content_item_id uuid,
  signal_type public.learning_signal_type not null,
  dimension text not null check (btrim(dimension) <> ''),
  value jsonb not null,
  weight numeric(8, 4) not null default 1,
  source text,
  observed_at timestamptz not null default now(),
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (brand_id, organization_id)
    references public.brands (id, organization_id) on delete cascade,
  foreign key (content_item_id, organization_id)
    references public.content_items (id, organization_id)
    on delete set null (content_item_id),
  unique (id, organization_id)
);

create table public.performance_insights (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  brand_id uuid not null,
  content_item_id uuid,
  headline text not null check (btrim(headline) <> ''),
  explanation text not null,
  evidence jsonb not null default '[]'::jsonb,
  confidence numeric(4, 3) check (confidence is null or confidence between 0 and 1),
  valid_from timestamptz not null default now(),
  valid_until timestamptz,
  created_at timestamptz not null default now(),
  foreign key (brand_id, organization_id)
    references public.brands (id, organization_id) on delete cascade,
  foreign key (content_item_id, organization_id)
    references public.content_items (id, organization_id)
    on delete set null (content_item_id),
  unique (id, organization_id)
);

create table public.recommendations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  brand_id uuid not null,
  recommendation_type text not null check (btrim(recommendation_type) <> ''),
  headline text not null check (btrim(headline) <> ''),
  reasoning text not null,
  proposed_change jsonb not null,
  status public.recommendation_status not null default 'pending',
  responded_by uuid references public.profiles (id) on delete set null,
  responded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (brand_id, organization_id)
    references public.brands (id, organization_id) on delete cascade,
  unique (id, organization_id)
);

create table public.usage_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  brand_id uuid,
  content_item_id uuid,
  generation_job_id uuid,
  event_type text not null check (btrim(event_type) <> ''),
  quantity numeric(14, 4) not null default 1 check (quantity >= 0),
  unit text not null default 'event',
  provider text,
  model text,
  cost numeric(12, 6) check (cost is null or cost >= 0),
  metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  foreign key (brand_id, organization_id)
    references public.brands (id, organization_id)
    on delete set null (brand_id),
  foreign key (content_item_id, organization_id)
    references public.content_items (id, organization_id)
    on delete set null (content_item_id),
  foreign key (generation_job_id, organization_id)
    references public.generation_jobs (id, organization_id)
    on delete set null (generation_job_id),
  unique (id, organization_id)
);

create table public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null unique references public.organizations (id) on delete cascade,
  plan_code text not null,
  status public.subscription_status not null default 'trialing',
  provider text,
  provider_customer_id text unique,
  provider_subscription_id text unique,
  trial_started_at timestamptz,
  trial_ends_at timestamptz,
  current_period_started_at timestamptz,
  current_period_ends_at timestamptz,
  cancel_at_period_end boolean not null default false,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, organization_id)
);

create function public.handle_new_organization_subscription()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.subscriptions (
    organization_id,
    plan_code,
    status,
    trial_started_at
  )
  values (new.id, 'trial', 'trialing', now())
  on conflict (organization_id) do nothing;

  return new;
end;
$$;

create trigger on_organization_subscription_created
  after insert on public.organizations
  for each row execute function public.handle_new_organization_subscription();

insert into public.subscriptions (
  organization_id,
  plan_code,
  status,
  trial_started_at,
  created_at,
  updated_at
)
select
  organization.id,
  'trial',
  'trialing',
  organization.created_at,
  organization.created_at,
  organization.updated_at
from public.organizations as organization
on conflict (organization_id) do nothing;

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  content_item_id uuid,
  type public.notification_type not null,
  title text not null check (btrim(title) <> ''),
  message text not null,
  action_url text,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (content_item_id, organization_id)
    references public.content_items (id, organization_id)
    on delete set null (content_item_id),
  unique (id, organization_id)
);

create index schedules_due_idx
  on public.schedules (status, scheduled_for)
  where status = 'scheduled';
create index schedules_content_item_idx on public.schedules (content_item_id);
create index publish_jobs_work_queue_idx
  on public.publish_jobs (state, next_attempt_at, created_at)
  where state in ('queued', 'retrying');
create index publish_attempts_job_idx on public.publish_attempts (publish_job_id, attempt_number);
create index published_posts_content_item_idx on public.published_posts (content_item_id);
create index metric_snapshots_post_captured_idx
  on public.metric_snapshots (published_post_id, captured_at desc);
create index generation_jobs_work_queue_idx
  on public.generation_jobs (state, created_at)
  where state in ('queued', 'retrying');
create index generation_jobs_content_item_idx on public.generation_jobs (content_item_id);
create index learning_signals_brand_dimension_idx
  on public.learning_signals (brand_id, dimension, observed_at desc);
create index performance_insights_brand_valid_idx
  on public.performance_insights (brand_id, valid_from desc);
create index recommendations_brand_status_idx
  on public.recommendations (brand_id, status, created_at desc);
create index usage_events_organization_occurred_idx
  on public.usage_events (organization_id, occurred_at desc);
create index notifications_user_unread_idx
  on public.notifications (user_id, created_at desc)
  where read_at is null;

create trigger set_schedules_updated_at before update on public.schedules
  for each row execute function public.set_updated_at();
create trigger set_publish_jobs_updated_at before update on public.publish_jobs
  for each row execute function public.set_updated_at();
create trigger set_published_posts_updated_at before update on public.published_posts
  for each row execute function public.set_updated_at();
create trigger set_generation_jobs_updated_at before update on public.generation_jobs
  for each row execute function public.set_updated_at();
create trigger set_recommendations_updated_at before update on public.recommendations
  for each row execute function public.set_updated_at();
create trigger set_subscriptions_updated_at before update on public.subscriptions
  for each row execute function public.set_updated_at();

alter table public.schedules enable row level security;
alter table public.publish_jobs enable row level security;
alter table public.publish_attempts enable row level security;
alter table public.published_posts enable row level security;
alter table public.metric_snapshots enable row level security;
alter table public.generation_jobs enable row level security;
alter table public.learning_signals enable row level security;
alter table public.performance_insights enable row level security;
alter table public.recommendations enable row level security;
alter table public.usage_events enable row level security;
alter table public.subscriptions enable row level security;
alter table public.notifications enable row level security;

create policy "Organization members can manage schedules"
  on public.schedules for all to authenticated
  using ((select public.is_organization_member(organization_id)))
  with check ((select public.is_organization_member(organization_id)));

create policy "Organization members can view publish jobs"
  on public.publish_jobs for select to authenticated
  using ((select public.is_organization_member(organization_id)));
create policy "Organization members can view publish attempts"
  on public.publish_attempts for select to authenticated
  using ((select public.is_organization_member(organization_id)));
create policy "Organization members can view published posts"
  on public.published_posts for select to authenticated
  using ((select public.is_organization_member(organization_id)));
create policy "Organization members can view metric snapshots"
  on public.metric_snapshots for select to authenticated
  using ((select public.is_organization_member(organization_id)));
create policy "Organization members can view generation jobs"
  on public.generation_jobs for select to authenticated
  using ((select public.is_organization_member(organization_id)));

create policy "Organization members can view learning signals"
  on public.learning_signals for select to authenticated
  using ((select public.is_organization_member(organization_id)));
create policy "Organization members can create learning signals"
  on public.learning_signals for insert to authenticated
  with check (
    (select public.is_organization_member(organization_id))
    and created_by = (select auth.uid())
  );

create policy "Organization members can view performance insights"
  on public.performance_insights for select to authenticated
  using ((select public.is_organization_member(organization_id)));

create policy "Organization members can view recommendations"
  on public.recommendations for select to authenticated
  using ((select public.is_organization_member(organization_id)));
create policy "Organization members can respond to recommendations"
  on public.recommendations for update to authenticated
  using ((select public.is_organization_member(organization_id)))
  with check (
    (select public.is_organization_member(organization_id))
    and status in ('accepted', 'ignored')
    and responded_by = (select auth.uid())
    and responded_at is not null
  );

create policy "Organization members can view usage"
  on public.usage_events for select to authenticated
  using ((select public.is_organization_member(organization_id)));
create policy "Organization members can view subscriptions"
  on public.subscriptions for select to authenticated
  using ((select public.is_organization_member(organization_id)));

create policy "Users can view their notifications"
  on public.notifications for select to authenticated
  using (
    user_id = (select auth.uid())
    and (select public.is_organization_member(organization_id))
  );
create policy "Users can update their notifications"
  on public.notifications for update to authenticated
  using (
    user_id = (select auth.uid())
    and (select public.is_organization_member(organization_id))
  )
  with check (
    user_id = (select auth.uid())
    and (select public.is_organization_member(organization_id))
  );
create policy "Users can delete their notifications"
  on public.notifications for delete to authenticated
  using (
    user_id = (select auth.uid())
    and (select public.is_organization_member(organization_id))
  );

grant select, insert, update, delete on table public.schedules to authenticated;
grant select on table
  public.publish_jobs,
  public.publish_attempts,
  public.published_posts,
  public.metric_snapshots,
  public.generation_jobs,
  public.performance_insights,
  public.usage_events,
  public.subscriptions
to authenticated;
grant select, insert on table public.learning_signals to authenticated;
grant select on table public.recommendations to authenticated;
grant update (status, responded_by, responded_at)
  on table public.recommendations to authenticated;
grant select, delete on table public.notifications to authenticated;
grant update (read_at) on table public.notifications to authenticated;
grant all on table
  public.schedules,
  public.publish_jobs,
  public.publish_attempts,
  public.published_posts,
  public.metric_snapshots,
  public.generation_jobs,
  public.learning_signals,
  public.performance_insights,
  public.recommendations,
  public.usage_events,
  public.subscriptions,
  public.notifications
to service_role;

revoke all on table
  public.schedules,
  public.publish_jobs,
  public.publish_attempts,
  public.published_posts,
  public.metric_snapshots,
  public.generation_jobs,
  public.learning_signals,
  public.performance_insights,
  public.recommendations,
  public.usage_events,
  public.subscriptions,
  public.notifications
from anon;

revoke execute on function public.handle_new_organization_subscription() from public;
