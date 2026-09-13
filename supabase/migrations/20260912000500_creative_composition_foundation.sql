create type public.creative_project_status as enum ('draft','composing','ready','archived');
create type public.creative_recipe_status as enum ('experimental','validated','proven','high_performer');
create type public.creative_render_status as enum ('queued','rendering','ready','failed','superseded');

create table public.creative_recipes (
  id uuid primary key default gen_random_uuid(),
  key text not null check (key = lower(key) and key ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  version integer not null check (version > 0),
  name text not null check (btrim(name) <> ''),
  status public.creative_recipe_status not null default 'experimental',
  schema_version integer not null default 1 check (schema_version > 0),
  manifest jsonb not null check (jsonb_typeof(manifest) = 'object'),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (key, version),
  unique (id, version)
);

create table public.creative_projects (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  content_item_id uuid not null,
  creative_brief_id uuid,
  selected_creative_variant_id uuid,
  recipe_id uuid,
  recipe_version integer,
  status public.creative_project_status not null default 'draft',
  schema_version integer not null default 1 check (schema_version > 0),
  manifest jsonb not null check (jsonb_typeof(manifest) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (content_item_id, organization_id) references public.content_items(id, organization_id) on delete cascade,
  foreign key (creative_brief_id, content_item_id, organization_id) references public.creative_briefs(id, content_item_id, organization_id) on delete set null (creative_brief_id),
  foreign key (selected_creative_variant_id, content_item_id, organization_id) references public.creative_variants(id, content_item_id, organization_id) on delete set null (selected_creative_variant_id),
  foreign key (recipe_id, recipe_version) references public.creative_recipes(id, version),
  unique (content_item_id),
  unique (id, organization_id),
  unique (id, content_item_id, organization_id)
);

create table public.creative_compositions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  creative_project_id uuid not null,
  content_item_id uuid not null,
  revision integer not null check (revision > 0),
  content_revision integer not null check (content_revision > 0),
  schema_version integer not null default 1 check (schema_version > 0),
  manifest jsonb not null check (jsonb_typeof(manifest) = 'object'),
  quality_report jsonb check (quality_report is null or jsonb_typeof(quality_report) = 'object'),
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles(id) on delete set null,
  foreign key (creative_project_id, content_item_id, organization_id) references public.creative_projects(id, content_item_id, organization_id) on delete cascade,
  unique (creative_project_id, revision),
  unique (id, organization_id),
  unique (id, content_item_id, organization_id),
  unique (id, creative_project_id, content_item_id, revision)
);

create table public.render_outputs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  content_item_id uuid not null,
  creative_project_id uuid not null,
  composition_id uuid not null,
  composition_revision integer not null check (composition_revision > 0),
  content_revision integer not null check (content_revision > 0),
  platform public.social_platform not null,
  status public.creative_render_status not null default 'queued',
  media_asset_id uuid,
  generation_job_id uuid,
  manifest jsonb not null check (jsonb_typeof(manifest) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (creative_project_id, content_item_id, organization_id) references public.creative_projects(id, content_item_id, organization_id) on delete cascade,
  foreign key (composition_id, creative_project_id, content_item_id, composition_revision) references public.creative_compositions(id, creative_project_id, content_item_id, revision) on delete cascade,
  foreign key (media_asset_id, content_item_id, organization_id) references public.media_assets(id, content_item_id, organization_id) on delete set null,
  foreign key (generation_job_id, organization_id) references public.generation_jobs(id, organization_id) on delete set null,
  unique (composition_id, platform),
  unique (id, organization_id)
);

create trigger set_creative_recipes_updated_at before update on public.creative_recipes for each row execute function public.set_updated_at();
create trigger set_creative_projects_updated_at before update on public.creative_projects for each row execute function public.set_updated_at();
create trigger set_render_outputs_updated_at before update on public.render_outputs for each row execute function public.set_updated_at();

create function public.guard_creative_composition_revision()
returns trigger language plpgsql set search_path = '' as $$
declare current_revision integer; expected_revision integer;
begin
  if tg_op = 'UPDATE' then
    if new.creative_project_id <> old.creative_project_id
      or new.content_item_id <> old.content_item_id
      or new.organization_id <> old.organization_id
      or new.revision <> old.revision
      or new.content_revision <> old.content_revision
      or new.schema_version <> old.schema_version
      or new.manifest <> old.manifest then
      raise exception 'Creative composition revisions are immutable' using errcode = '22023';
    end if;
    return new;
  end if;
  select content_revision into current_revision from public.content_items
    where id = new.content_item_id and organization_id = new.organization_id;
  if current_revision is null or current_revision <> new.content_revision then
    raise exception 'Creative composition content revision is stale' using errcode = '40001';
  end if;
  select coalesce(max(revision) + 1, 1) into expected_revision from public.creative_compositions
    where creative_project_id = new.creative_project_id;
  if new.revision <> expected_revision then
    raise exception 'Creative composition revision must be sequential' using errcode = '22023';
  end if;
  return new;
end $$;

create trigger guard_creative_composition_revision before insert or update on public.creative_compositions
  for each row execute function public.guard_creative_composition_revision();

create function public.supersede_previous_render_outputs()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.render_outputs set status = 'superseded'
    where creative_project_id = new.creative_project_id
      and composition_revision < new.revision
      and status in ('queued','rendering','ready','failed');
  return new;
end $$;

create trigger supersede_previous_render_outputs after insert on public.creative_compositions
  for each row execute function public.supersede_previous_render_outputs();

revoke all on function public.guard_creative_composition_revision() from public;
revoke all on function public.supersede_previous_render_outputs() from public;

alter table public.creative_recipes enable row level security;
alter table public.creative_projects enable row level security;
alter table public.creative_compositions enable row level security;
alter table public.render_outputs enable row level security;

create policy "Authenticated users can view active creative recipes" on public.creative_recipes for select to authenticated using (is_active);
create policy "Organization members can manage creative projects" on public.creative_projects for all to authenticated using ((select public.is_organization_member(organization_id))) with check ((select public.is_organization_member(organization_id)));
create policy "Organization members can manage creative compositions" on public.creative_compositions for all to authenticated using ((select public.is_organization_member(organization_id))) with check ((select public.is_organization_member(organization_id)));
create policy "Organization members can view render outputs" on public.render_outputs for select to authenticated using ((select public.is_organization_member(organization_id)));

grant select on table public.creative_recipes, public.render_outputs to authenticated;
grant select, insert, update, delete on table public.creative_projects to authenticated;
grant select, insert on table public.creative_compositions to authenticated;
