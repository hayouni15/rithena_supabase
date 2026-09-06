-- Planning, creative production, platform adaptation, QA, and review.

create type public.campaign_status as enum (
  'draft',
  'active',
  'completed',
  'cancelled',
  'archived'
);

create type public.content_plan_status as enum (
  'draft',
  'generating',
  'ready',
  'active',
  'archived'
);

create type public.content_format as enum (
  'image',
  'carousel',
  'short_video',
  'text'
);

create type public.content_item_status as enum (
  'draft_plan',
  'planned',
  'generating',
  'qa',
  'ready_for_review',
  'approved',
  'scheduled',
  'publishing',
  'published',
  'failed',
  'skipped',
  'archived'
);

create type public.creative_variant_kind as enum (
  'hook',
  'first_frame',
  'visual_direction',
  'pacing',
  'voiceover',
  'cta',
  'caption',
  'duration',
  'music_mood',
  'complete'
);

create type public.media_asset_type as enum (
  'image',
  'video',
  'audio',
  'thumbnail',
  'carousel_slide',
  'document'
);

create type public.media_origin as enum (
  'generated',
  'uploaded',
  'rendered',
  'imported'
);

create type public.media_asset_status as enum (
  'pending',
  'processing',
  'ready',
  'failed',
  'archived'
);

create type public.platform_variant_status as enum (
  'draft',
  'generating',
  'ready',
  'approved',
  'scheduled',
  'published',
  'failed',
  'archived'
);

create type public.qa_check_type as enum (
  'brand_accuracy',
  'copy',
  'visual',
  'video',
  'policy'
);

create type public.qa_action as enum (
  'accept',
  'auto_fix',
  'regenerate',
  'human_review'
);

create type public.approval_decision as enum (
  'requested',
  'approved',
  'rejected',
  'changes_requested',
  'skipped'
);

create table public.campaigns (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  brand_id uuid not null,
  name text not null check (btrim(name) <> ''),
  objective text not null check (btrim(objective) <> ''),
  starts_on date,
  ends_on date,
  verified_facts jsonb not null default '[]'::jsonb,
  offer text,
  audience text,
  call_to_action text,
  target_quantity integer check (target_quantity is null or target_quantity > 0),
  platform_targets public.social_platform[] not null default '{}',
  approval_policy public.approval_policy not null default 'review',
  status public.campaign_status not null default 'draft',
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_on is null or starts_on is null or ends_on >= starts_on),
  foreign key (brand_id, organization_id)
    references public.brands (id, organization_id) on delete cascade,
  unique (id, organization_id)
);

create table public.content_plans (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  brand_id uuid not null,
  starts_on date not null,
  ends_on date not null,
  status public.content_plan_status not null default 'draft',
  strategy_summary text,
  strategy_inputs jsonb not null default '{}'::jsonb,
  version integer not null default 1 check (version > 0),
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_on >= starts_on),
  foreign key (brand_id, organization_id)
    references public.brands (id, organization_id) on delete cascade,
  unique (brand_id, starts_on, ends_on, version),
  unique (id, organization_id)
);

create table public.content_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  brand_id uuid not null,
  content_plan_id uuid,
  campaign_id uuid,
  content_pillar_id uuid,
  planned_for date,
  platform_targets public.social_platform[] not null default '{}',
  format public.content_format not null,
  archetype_key text,
  working_title text not null check (btrim(working_title) <> ''),
  hook text,
  concept text,
  creative_direction text,
  call_to_action text,
  risk_level public.risk_level not null default 'low',
  status public.content_item_status not null default 'draft_plan',
  failure_code text,
  failure_message text,
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (brand_id, organization_id)
    references public.brands (id, organization_id) on delete cascade,
  foreign key (content_plan_id, organization_id)
    references public.content_plans (id, organization_id)
    on delete set null (content_plan_id),
  foreign key (campaign_id, organization_id)
    references public.campaigns (id, organization_id)
    on delete set null (campaign_id),
  foreign key (content_pillar_id, organization_id)
    references public.content_pillars (id, organization_id)
    on delete set null (content_pillar_id),
  unique (id, organization_id)
);

comment on table public.content_items is
  'Canonical content record shared by planning, review, calendar, publishing, and analytics.';

create table public.creative_archetypes (
  id uuid primary key default gen_random_uuid(),
  key text not null unique check (btrim(key) <> ''),
  name text not null check (btrim(name) <> ''),
  description text,
  supported_formats public.content_format[] not null default '{}',
  supported_goals public.goal_type[] not null default '{}',
  suitable_industries text[] not null default '{}',
  risk_level public.risk_level not null default 'low',
  structure jsonb not null default '[]'::jsonb,
  required_inputs text[] not null default '{}',
  optional_inputs text[] not null default '{}',
  default_min_duration_seconds integer,
  default_max_duration_seconds integer,
  default_approval_policy public.approval_policy not null default 'review',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    default_min_duration_seconds is null
    or default_min_duration_seconds >= 0
  ),
  check (
    default_max_duration_seconds is null
    or default_max_duration_seconds >= coalesce(default_min_duration_seconds, 0)
  )
);

alter table public.content_items
  add constraint content_items_archetype_key_fkey
  foreign key (archetype_key)
  references public.creative_archetypes (key)
  on delete set null;

create table public.creative_briefs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  content_item_id uuid not null,
  creative_archetype_id uuid references public.creative_archetypes (id) on delete set null,
  objective text,
  viewer text,
  hook text,
  story text,
  emotional_tone text,
  visual_treatment text,
  shot_plan jsonb not null default '[]'::jsonb,
  text_overlay_plan jsonb not null default '[]'::jsonb,
  brand_elements jsonb not null default '[]'::jsonb,
  call_to_action text,
  audio_direction text,
  platform_constraints jsonb not null default '{}'::jsonb,
  version integer not null default 1 check (version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (content_item_id, organization_id)
    references public.content_items (id, organization_id) on delete cascade,
  unique (content_item_id, version),
  unique (id, organization_id),
  unique (id, content_item_id, organization_id)
);

create table public.creative_variants (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  content_item_id uuid not null,
  creative_brief_id uuid not null,
  variant_kind public.creative_variant_kind not null default 'complete',
  direction text,
  generation_parameters jsonb not null default '{}'::jsonb,
  version integer not null default 1 check (version > 0),
  is_selected boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (content_item_id, organization_id)
    references public.content_items (id, organization_id) on delete cascade,
  foreign key (creative_brief_id, content_item_id, organization_id)
    references public.creative_briefs (id, content_item_id, organization_id)
    on delete cascade,
  unique (creative_brief_id, variant_kind, version),
  unique (id, organization_id),
  unique (id, content_item_id, organization_id)
);

create table public.media_assets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  content_item_id uuid not null,
  creative_variant_id uuid,
  asset_type public.media_asset_type not null,
  origin public.media_origin not null,
  status public.media_asset_status not null default 'pending',
  storage_bucket text not null,
  storage_path text not null,
  mime_type text,
  width integer check (width is null or width > 0),
  height integer check (height is null or height > 0),
  duration_seconds numeric(10, 3) check (duration_seconds is null or duration_seconds >= 0),
  file_size_bytes bigint check (file_size_bytes is null or file_size_bytes >= 0),
  checksum text,
  provider text,
  provider_asset_id text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (content_item_id, organization_id)
    references public.content_items (id, organization_id) on delete cascade,
  foreign key (creative_variant_id, content_item_id, organization_id)
    references public.creative_variants (id, content_item_id, organization_id)
    on delete set null (creative_variant_id),
  unique (storage_bucket, storage_path),
  unique (id, organization_id),
  unique (id, content_item_id, organization_id)
);

create table public.platform_variants (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  content_item_id uuid not null,
  platform public.social_platform not null,
  format public.content_format not null,
  status public.platform_variant_status not null default 'draft',
  aspect_ratio text,
  duration_seconds numeric(10, 3) check (duration_seconds is null or duration_seconds >= 0),
  platform_config jsonb not null default '{}'::jsonb,
  selected_media_asset_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (content_item_id, organization_id)
    references public.content_items (id, organization_id) on delete cascade,
  foreign key (selected_media_asset_id, content_item_id, organization_id)
    references public.media_assets (id, content_item_id, organization_id)
    on delete set null (selected_media_asset_id),
  unique (content_item_id, platform),
  unique (id, organization_id),
  unique (id, content_item_id, organization_id)
);

create table public.post_copies (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  platform_variant_id uuid not null,
  locale text not null default 'en',
  headline text,
  subhead text,
  caption text,
  hashtags text[] not null default '{}',
  call_to_action text,
  title text,
  description text,
  version integer not null default 1 check (version > 0),
  is_selected boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (platform_variant_id, organization_id)
    references public.platform_variants (id, organization_id) on delete cascade,
  unique (platform_variant_id, locale, version),
  unique (id, organization_id)
);

create table public.qa_checks (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  content_item_id uuid not null,
  media_asset_id uuid,
  check_type public.qa_check_type not null,
  passed boolean not null,
  score numeric(5, 2) check (score is null or score between 0 and 100),
  issues jsonb not null default '[]'::jsonb,
  action public.qa_action not null,
  checker text,
  checked_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  foreign key (content_item_id, organization_id)
    references public.content_items (id, organization_id) on delete cascade,
  foreign key (media_asset_id, content_item_id, organization_id)
    references public.media_assets (id, content_item_id, organization_id)
    on delete set null (media_asset_id),
  unique (id, organization_id)
);

create table public.approvals (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  content_item_id uuid not null,
  creative_variant_id uuid,
  decision public.approval_decision not null,
  feedback text,
  regenerate_direction text,
  decided_by uuid references public.profiles (id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (content_item_id, organization_id)
    references public.content_items (id, organization_id) on delete cascade,
  foreign key (creative_variant_id, content_item_id, organization_id)
    references public.creative_variants (id, content_item_id, organization_id)
    on delete set null (creative_variant_id),
  unique (id, organization_id)
);

create index campaigns_brand_status_idx on public.campaigns (brand_id, status);
create index content_plans_brand_dates_idx on public.content_plans (brand_id, starts_on, ends_on);
create index content_items_organization_status_idx
  on public.content_items (organization_id, status);
create index content_items_brand_planned_for_idx
  on public.content_items (brand_id, planned_for);
create index creative_briefs_content_item_idx on public.creative_briefs (content_item_id);
create index creative_variants_content_item_idx on public.creative_variants (content_item_id);
create index media_assets_content_item_status_idx on public.media_assets (content_item_id, status);
create index platform_variants_content_item_idx on public.platform_variants (content_item_id);
create index post_copies_platform_variant_idx on public.post_copies (platform_variant_id);
create index qa_checks_content_item_type_idx on public.qa_checks (content_item_id, check_type);
create index approvals_content_item_created_idx on public.approvals (content_item_id, created_at desc);

create trigger set_campaigns_updated_at before update on public.campaigns
  for each row execute function public.set_updated_at();
create trigger set_content_plans_updated_at before update on public.content_plans
  for each row execute function public.set_updated_at();
create trigger set_content_items_updated_at before update on public.content_items
  for each row execute function public.set_updated_at();
create trigger set_creative_archetypes_updated_at before update on public.creative_archetypes
  for each row execute function public.set_updated_at();
create trigger set_creative_briefs_updated_at before update on public.creative_briefs
  for each row execute function public.set_updated_at();
create trigger set_creative_variants_updated_at before update on public.creative_variants
  for each row execute function public.set_updated_at();
create trigger set_media_assets_updated_at before update on public.media_assets
  for each row execute function public.set_updated_at();
create trigger set_platform_variants_updated_at before update on public.platform_variants
  for each row execute function public.set_updated_at();
create trigger set_post_copies_updated_at before update on public.post_copies
  for each row execute function public.set_updated_at();

alter table public.campaigns enable row level security;
alter table public.content_plans enable row level security;
alter table public.content_items enable row level security;
alter table public.creative_archetypes enable row level security;
alter table public.creative_briefs enable row level security;
alter table public.creative_variants enable row level security;
alter table public.media_assets enable row level security;
alter table public.platform_variants enable row level security;
alter table public.post_copies enable row level security;
alter table public.qa_checks enable row level security;
alter table public.approvals enable row level security;

create policy "Authenticated users can view active creative archetypes"
  on public.creative_archetypes for select to authenticated
  using (is_active);

create policy "Organization members can manage campaigns"
  on public.campaigns for all to authenticated
  using ((select public.is_organization_member(organization_id)))
  with check ((select public.is_organization_member(organization_id)));
create policy "Organization members can manage content plans"
  on public.content_plans for all to authenticated
  using ((select public.is_organization_member(organization_id)))
  with check ((select public.is_organization_member(organization_id)));
create policy "Organization members can manage content items"
  on public.content_items for all to authenticated
  using ((select public.is_organization_member(organization_id)))
  with check ((select public.is_organization_member(organization_id)));
create policy "Organization members can manage creative briefs"
  on public.creative_briefs for all to authenticated
  using ((select public.is_organization_member(organization_id)))
  with check ((select public.is_organization_member(organization_id)));
create policy "Organization members can manage creative variants"
  on public.creative_variants for all to authenticated
  using ((select public.is_organization_member(organization_id)))
  with check ((select public.is_organization_member(organization_id)));
create policy "Organization members can manage media assets"
  on public.media_assets for all to authenticated
  using ((select public.is_organization_member(organization_id)))
  with check ((select public.is_organization_member(organization_id)));
create policy "Organization members can manage platform variants"
  on public.platform_variants for all to authenticated
  using ((select public.is_organization_member(organization_id)))
  with check ((select public.is_organization_member(organization_id)));
create policy "Organization members can manage post copies"
  on public.post_copies for all to authenticated
  using ((select public.is_organization_member(organization_id)))
  with check ((select public.is_organization_member(organization_id)));
create policy "Organization members can view QA checks"
  on public.qa_checks for select to authenticated
  using ((select public.is_organization_member(organization_id)));
create policy "Organization members can record approvals"
  on public.approvals for insert to authenticated
  with check (
    (select public.is_organization_member(organization_id))
    and (
      (decision = 'requested' and decided_by is null and decided_at is null)
      or (
        decision <> 'requested'
        and decided_by = (select auth.uid())
        and decided_at is not null
      )
    )
  );
create policy "Organization members can view approvals"
  on public.approvals for select to authenticated
  using ((select public.is_organization_member(organization_id)));

grant select on table public.creative_archetypes, public.qa_checks to authenticated;
grant select, insert, update, delete on table
  public.campaigns,
  public.content_plans,
  public.content_items,
  public.creative_briefs,
  public.creative_variants,
  public.media_assets,
  public.platform_variants,
  public.post_copies
to authenticated;
grant select, insert on table public.approvals to authenticated;
grant all on table
  public.campaigns,
  public.content_plans,
  public.content_items,
  public.creative_archetypes,
  public.creative_briefs,
  public.creative_variants,
  public.media_assets,
  public.platform_variants,
  public.post_copies,
  public.qa_checks,
  public.approvals
to service_role;

revoke all on table
  public.campaigns,
  public.content_plans,
  public.content_items,
  public.creative_archetypes,
  public.creative_briefs,
  public.creative_variants,
  public.media_assets,
  public.platform_variants,
  public.post_copies,
  public.qa_checks,
  public.approvals
from anon;
