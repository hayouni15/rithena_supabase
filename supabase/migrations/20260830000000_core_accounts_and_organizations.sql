-- Rithena core identity and tenant model.

create type public.organization_role as enum ('owner', 'admin', 'member');

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text,
  avatar_url text,
  timezone text not null default 'UTC',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is
  'Application identity data for a Supabase Auth user.';
comment on column public.profiles.timezone is
  'IANA timezone used for display and scheduling defaults.';

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (btrim(name) <> ''),
  slug text not null unique check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  timezone text not null default 'UTC',
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.organizations is
  'Tenant, workspace, and billing boundary.';

create table public.organization_members (
  organization_id uuid not null references public.organizations (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  role public.organization_role not null default 'member',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (organization_id, user_id)
);

comment on table public.organization_members is
  'Maps profiles to organizations and defines their organization-level role.';

create index organization_members_user_id_idx
  on public.organization_members (user_id, organization_id);

create function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name, avatar_url, timezone)
  values (
    new.id,
    coalesce(
      nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
      nullif(btrim(new.raw_user_meta_data ->> 'name'), '')
    ),
    coalesce(
      nullif(btrim(new.raw_user_meta_data ->> 'avatar_url'), ''),
      nullif(btrim(new.raw_user_meta_data ->> 'picture'), '')
    ),
    coalesce(nullif(btrim(new.raw_user_meta_data ->> 'timezone'), ''), 'UTC')
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

create function public.handle_new_organization()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.created_by is null then
    raise exception 'created_by is required when creating an organization';
  end if;

  insert into public.organization_members (organization_id, user_id, role)
  values (new.id, new.created_by, 'owner');

  return new;
end;
$$;

create function public.is_organization_member(target_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.organization_members as membership
    where membership.organization_id = target_organization_id
      and membership.user_id = (select auth.uid())
  );
$$;

create function public.has_organization_role(
  target_organization_id uuid,
  allowed_roles public.organization_role[]
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.organization_members as membership
    where membership.organization_id = target_organization_id
      and membership.user_id = (select auth.uid())
      and membership.role = any (allowed_roles)
  );
$$;

create trigger set_profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

create trigger set_organizations_updated_at
  before update on public.organizations
  for each row execute function public.set_updated_at();

create trigger set_organization_members_updated_at
  before update on public.organization_members
  for each row execute function public.set_updated_at();

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create trigger on_organization_created
  after insert on public.organizations
  for each row execute function public.handle_new_organization();

-- Backfill profiles if this schema is introduced after Auth users already exist.
insert into public.profiles (id, full_name, avatar_url, timezone, created_at, updated_at)
select
  users.id,
  coalesce(
    nullif(btrim(users.raw_user_meta_data ->> 'full_name'), ''),
    nullif(btrim(users.raw_user_meta_data ->> 'name'), '')
  ),
  coalesce(
    nullif(btrim(users.raw_user_meta_data ->> 'avatar_url'), ''),
    nullif(btrim(users.raw_user_meta_data ->> 'picture'), '')
  ),
  coalesce(nullif(btrim(users.raw_user_meta_data ->> 'timezone'), ''), 'UTC'),
  users.created_at,
  coalesce(users.updated_at, users.created_at)
from auth.users as users
on conflict (id) do nothing;

alter table public.profiles enable row level security;
alter table public.organizations enable row level security;
alter table public.organization_members enable row level security;

create policy "Users can view their own profile"
  on public.profiles for select to authenticated
  using ((select auth.uid()) = id);

create policy "Users can update their own profile"
  on public.profiles for update to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

create policy "Users can create their own profile"
  on public.profiles for insert to authenticated
  with check ((select auth.uid()) = id);

create policy "Members can view their organizations"
  on public.organizations for select to authenticated
  using ((select public.is_organization_member(id)));

create policy "Users can create organizations"
  on public.organizations for insert to authenticated
  with check (created_by = (select auth.uid()));

create policy "Owners and admins can update organizations"
  on public.organizations for update to authenticated
  using ((select public.has_organization_role(id, array['owner', 'admin']::public.organization_role[])))
  with check ((select public.has_organization_role(id, array['owner', 'admin']::public.organization_role[])));

create policy "Owners can delete organizations"
  on public.organizations for delete to authenticated
  using ((select public.has_organization_role(id, array['owner']::public.organization_role[])));

create policy "Members can view organization memberships"
  on public.organization_members for select to authenticated
  using ((select public.is_organization_member(organization_id)));

create policy "Owners can manage organization members"
  on public.organization_members for all to authenticated
  using ((select public.has_organization_role(
    organization_id,
    array['owner']::public.organization_role[]
  )))
  with check ((select public.has_organization_role(
    organization_id,
    array['owner']::public.organization_role[]
  )));

create policy "Admins can add members"
  on public.organization_members for insert to authenticated
  with check (
    role = 'member'
    and (select public.has_organization_role(
      organization_id,
      array['admin']::public.organization_role[]
    ))
  );

create policy "Admins can update members"
  on public.organization_members for update to authenticated
  using (
    role = 'member'
    and (select public.has_organization_role(
      organization_id,
      array['admin']::public.organization_role[]
    ))
  )
  with check (
    role = 'member'
    and (select public.has_organization_role(
      organization_id,
      array['admin']::public.organization_role[]
    ))
  );

create policy "Admins can remove members"
  on public.organization_members for delete to authenticated
  using (
    role = 'member'
    and (select public.has_organization_role(
      organization_id,
      array['admin']::public.organization_role[]
    ))
  );

grant usage on schema public to authenticated;
grant select, insert, update on table public.profiles to authenticated;
grant select, insert, update, delete on table public.organizations to authenticated;
grant select, insert, update, delete on table public.organization_members to authenticated;
grant all on table
  public.profiles,
  public.organizations,
  public.organization_members
to service_role;

revoke all on table public.profiles from anon;
revoke all on table public.organizations from anon;
revoke all on table public.organization_members from anon;

revoke execute on function public.set_updated_at() from public;
revoke execute on function public.handle_new_user() from public;
revoke execute on function public.handle_new_organization() from public;
revoke execute on function public.is_organization_member(uuid) from public;
revoke execute on function public.has_organization_role(uuid, public.organization_role[]) from public;

grant execute on function public.is_organization_member(uuid) to authenticated;
grant execute on function public.has_organization_role(uuid, public.organization_role[]) to authenticated;
