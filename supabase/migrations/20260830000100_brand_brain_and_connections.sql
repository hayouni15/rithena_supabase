-- Brand Brain, goals, autopilot policy, and publishing connections.

create type public.brand_status as enum (
  'draft',
  'learning',
  'needs_confirmation',
  'active',
  'paused',
  'archived'
);

create type public.brand_source_type as enum (
  'website',
  'social_profile',
  'upload',
  'manual'
);

create type public.ingestion_status as enum (
  'pending',
  'processing',
  'succeeded',
  'failed'
);

create type public.fact_verification_status as enum (
  'verified',
  'user_confirmed',
  'unverified'
);

create type public.brand_asset_type as enum (
  'logo',
  'image',
  'video',
  'font',
  'document',
  'color_palette',
  'other'
);

create type public.goal_type as enum (
  'stay_visible',
  'get_leads',
  'build_authority',
  'educate',
  'grow_audience',
  'promote_products'
);

create type public.social_platform as enum (
  'instagram',
  'facebook',
  'linkedin',
  'tiktok',
  'youtube'
);

create type public.connection_status as enum (
  'pending',
  'connected',
  'expired',
  'revoked',
  'error'
);

create type public.autopilot_mode as enum (
  'review_everything',
  'trusted_autopilot',
  'full_autopilot'
);

create type public.risk_level as enum ('low', 'medium', 'high');
create type public.approval_policy as enum ('auto', 'review');

create table public.industry_playbooks (
  id uuid primary key default gen_random_uuid(),
  key text not null unique check (btrim(key) <> ''),
  name text not null check (btrim(name) <> ''),
  description text,
  strategy_config jsonb not null default '{}'::jsonb,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.brands (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  industry_playbook_id uuid references public.industry_playbooks (id) on delete set null,
  name text not null check (btrim(name) <> ''),
  slug text not null check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  website_url text,
  description text,
  industry text,
  geography text,
  timezone text not null default 'UTC',
  status public.brand_status not null default 'draft',
  default_autopilot_mode public.autopilot_mode not null default 'review_everything',
  onboarding_completed_at timestamptz,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, slug),
  unique (id, organization_id)
);

comment on table public.brands is
  'Organization-owned business identity and root of the Brand Brain.';

create table public.brand_sources (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  brand_id uuid not null,
  source_type public.brand_source_type not null,
  source_url text,
  source_label text,
  ingestion_status public.ingestion_status not null default 'pending',
  snapshot_storage_path text,
  extracted_data jsonb not null default '{}'::jsonb,
  last_ingested_at timestamptz,
  error_code text,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (brand_id, organization_id)
    references public.brands (id, organization_id) on delete cascade,
  unique (id, organization_id)
);

create table public.brand_facts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  brand_id uuid not null,
  brand_source_id uuid,
  key text not null check (btrim(key) <> ''),
  value text not null check (btrim(value) <> ''),
  confidence numeric(4, 3) not null default 0
    check (confidence between 0 and 1),
  verification_status public.fact_verification_status not null default 'unverified',
  source_url text,
  source_excerpt text,
  last_verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (brand_id, organization_id)
    references public.brands (id, organization_id) on delete cascade,
  foreign key (brand_source_id, organization_id)
    references public.brand_sources (id, organization_id)
    on delete set null (brand_source_id),
  unique (brand_id, key),
  unique (id, organization_id)
);

comment on table public.brand_facts is
  'Business claims with confidence, verification state, and source provenance.';

create table public.brand_preferences (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  brand_id uuid not null,
  category text not null check (btrim(category) <> ''),
  key text not null check (btrim(key) <> ''),
  value jsonb not null,
  weight numeric(6, 3) not null default 1,
  evidence_count integer not null default 0 check (evidence_count >= 0),
  is_explicit boolean not null default false,
  last_observed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (brand_id, organization_id)
    references public.brands (id, organization_id) on delete cascade,
  unique (brand_id, category, key),
  unique (id, organization_id)
);

create table public.brand_assets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  brand_id uuid not null,
  asset_type public.brand_asset_type not null,
  label text,
  storage_bucket text not null,
  storage_path text not null,
  mime_type text,
  width integer check (width is null or width > 0),
  height integer check (height is null or height > 0),
  duration_seconds numeric(10, 3) check (duration_seconds is null or duration_seconds >= 0),
  metadata jsonb not null default '{}'::jsonb,
  is_primary boolean not null default false,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (brand_id, organization_id)
    references public.brands (id, organization_id) on delete cascade,
  unique (brand_id, storage_bucket, storage_path),
  unique (id, organization_id)
);

create table public.goals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  brand_id uuid not null,
  goal_type public.goal_type not null,
  priority smallint not null default 1 check (priority > 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (brand_id, organization_id)
    references public.brands (id, organization_id) on delete cascade,
  unique (brand_id, goal_type),
  unique (id, organization_id)
);

create table public.content_pillars (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  brand_id uuid not null,
  name text not null check (btrim(name) <> ''),
  description text,
  target_percentage numeric(5, 2) not null
    check (target_percentage between 0 and 100),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (brand_id, organization_id)
    references public.brands (id, organization_id) on delete cascade,
  unique (brand_id, name),
  unique (id, organization_id)
);

create table public.autopilot_policies (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  brand_id uuid not null,
  mode public.autopilot_mode not null,
  content_category text not null check (btrim(content_category) <> ''),
  risk_level public.risk_level not null,
  approval_policy public.approval_policy not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (brand_id, organization_id)
    references public.brands (id, organization_id) on delete cascade,
  unique (brand_id, mode, content_category),
  unique (id, organization_id)
);

create table public.social_connections (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  brand_id uuid not null,
  platform public.social_platform not null,
  provider_account_id text not null,
  provider_account_name text,
  provider_account_handle text,
  status public.connection_status not null default 'pending',
  scopes text[] not null default '{}',
  credentials_reference text,
  token_expires_at timestamptz,
  last_validated_at timestamptz,
  last_successful_publish_at timestamptz,
  last_error_code text,
  last_error_message text,
  metadata jsonb not null default '{}'::jsonb,
  connected_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (brand_id, organization_id)
    references public.brands (id, organization_id) on delete cascade,
  unique (brand_id, platform, provider_account_id),
  unique (id, organization_id)
);

comment on column public.social_connections.credentials_reference is
  'Opaque reference to encrypted server-side OAuth credentials; never a plaintext token.';

create index brands_organization_id_idx on public.brands (organization_id);
create index brand_sources_brand_id_idx on public.brand_sources (brand_id);
create index brand_facts_brand_id_verification_idx
  on public.brand_facts (brand_id, verification_status);
create index brand_preferences_brand_id_category_idx
  on public.brand_preferences (brand_id, category);
create index brand_assets_brand_id_type_idx on public.brand_assets (brand_id, asset_type);
create index goals_brand_id_active_idx on public.goals (brand_id, is_active);
create index content_pillars_brand_id_active_idx on public.content_pillars (brand_id, is_active);
create index social_connections_brand_id_status_idx
  on public.social_connections (brand_id, status);

create trigger set_industry_playbooks_updated_at
  before update on public.industry_playbooks
  for each row execute function public.set_updated_at();
create trigger set_brands_updated_at
  before update on public.brands
  for each row execute function public.set_updated_at();
create trigger set_brand_sources_updated_at
  before update on public.brand_sources
  for each row execute function public.set_updated_at();
create trigger set_brand_facts_updated_at
  before update on public.brand_facts
  for each row execute function public.set_updated_at();
create trigger set_brand_preferences_updated_at
  before update on public.brand_preferences
  for each row execute function public.set_updated_at();
create trigger set_brand_assets_updated_at
  before update on public.brand_assets
  for each row execute function public.set_updated_at();
create trigger set_goals_updated_at
  before update on public.goals
  for each row execute function public.set_updated_at();
create trigger set_content_pillars_updated_at
  before update on public.content_pillars
  for each row execute function public.set_updated_at();
create trigger set_autopilot_policies_updated_at
  before update on public.autopilot_policies
  for each row execute function public.set_updated_at();
create trigger set_social_connections_updated_at
  before update on public.social_connections
  for each row execute function public.set_updated_at();

alter table public.industry_playbooks enable row level security;
alter table public.brands enable row level security;
alter table public.brand_sources enable row level security;
alter table public.brand_facts enable row level security;
alter table public.brand_preferences enable row level security;
alter table public.brand_assets enable row level security;
alter table public.goals enable row level security;
alter table public.content_pillars enable row level security;
alter table public.autopilot_policies enable row level security;
alter table public.social_connections enable row level security;

create policy "Authenticated users can view active industry playbooks"
  on public.industry_playbooks for select to authenticated
  using (is_active);

create policy "Organization members can manage brands"
  on public.brands for all to authenticated
  using ((select public.is_organization_member(organization_id)))
  with check ((select public.is_organization_member(organization_id)));

create policy "Organization members can manage brand sources"
  on public.brand_sources for all to authenticated
  using ((select public.is_organization_member(organization_id)))
  with check ((select public.is_organization_member(organization_id)));

create policy "Organization members can manage brand facts"
  on public.brand_facts for all to authenticated
  using ((select public.is_organization_member(organization_id)))
  with check ((select public.is_organization_member(organization_id)));

create policy "Organization members can manage brand preferences"
  on public.brand_preferences for all to authenticated
  using ((select public.is_organization_member(organization_id)))
  with check ((select public.is_organization_member(organization_id)));

create policy "Organization members can manage brand assets"
  on public.brand_assets for all to authenticated
  using ((select public.is_organization_member(organization_id)))
  with check ((select public.is_organization_member(organization_id)));

create policy "Organization members can manage goals"
  on public.goals for all to authenticated
  using ((select public.is_organization_member(organization_id)))
  with check ((select public.is_organization_member(organization_id)));

create policy "Organization members can manage content pillars"
  on public.content_pillars for all to authenticated
  using ((select public.is_organization_member(organization_id)))
  with check ((select public.is_organization_member(organization_id)));

create policy "Organization members can manage autopilot policies"
  on public.autopilot_policies for all to authenticated
  using ((select public.is_organization_member(organization_id)))
  with check ((select public.is_organization_member(organization_id)));

create policy "Organization members can view social connections"
  on public.social_connections for select to authenticated
  using ((select public.is_organization_member(organization_id)));

grant select on table public.industry_playbooks to authenticated;
grant select, insert, update, delete on table
  public.brands,
  public.brand_sources,
  public.brand_facts,
  public.brand_preferences,
  public.brand_assets,
  public.goals,
  public.content_pillars,
  public.autopilot_policies
to authenticated;
grant select on table public.social_connections to authenticated;
grant all on table
  public.industry_playbooks,
  public.brands,
  public.brand_sources,
  public.brand_facts,
  public.brand_preferences,
  public.brand_assets,
  public.goals,
  public.content_pillars,
  public.autopilot_policies,
  public.social_connections
to service_role;

revoke all on table
  public.industry_playbooks,
  public.brands,
  public.brand_sources,
  public.brand_facts,
  public.brand_preferences,
  public.brand_assets,
  public.goals,
  public.content_pillars,
  public.autopilot_policies,
  public.social_connections
from anon;
