-- Track Studio renders independently of media assets so failures can be reported.
create table public.video_render_requests (
  id uuid primary key,
  organization_id uuid not null,
  content_item_id uuid not null,
  state text not null default 'rendering' check (state in ('rendering', 'succeeded', 'failed')),
  error_message text,
  media_asset_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (content_item_id, organization_id)
    references public.content_items (id, organization_id) on delete cascade,
  foreign key (media_asset_id, content_item_id, organization_id)
    references public.media_assets (id, content_item_id, organization_id)
    on delete set null (media_asset_id)
);

create index video_render_requests_content_idx on public.video_render_requests (content_item_id, created_at desc);
create trigger set_video_render_requests_updated_at before update on public.video_render_requests
  for each row execute function public.set_updated_at();

alter table public.video_render_requests enable row level security;
create policy "Organization members can view video renders"
  on public.video_render_requests for select to authenticated
  using ((select public.is_organization_member(organization_id)));

grant select on table public.video_render_requests to authenticated;
grant all on table public.video_render_requests to service_role;
revoke all on table public.video_render_requests from anon;
