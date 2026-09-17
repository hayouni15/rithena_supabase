-- First-class products and an isolated product-reference generation queue.
create table public.products (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  brand_id uuid not null,
  name text not null check (char_length(btrim(name)) between 1 and 160),
  description text not null check (char_length(btrim(description)) between 1 and 2400),
  product_url text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (brand_id, organization_id) references public.brands(id, organization_id) on delete cascade,
  unique (id, organization_id)
);

create table public.product_assets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  product_id uuid not null,
  storage_bucket text not null default 'product-assets',
  storage_path text not null,
  mime_type text not null check (mime_type in ('image/png','image/jpeg','image/webp')),
  position smallint not null default 0 check (position between 0 and 20),
  created_at timestamptz not null default now(),
  foreign key (product_id, organization_id) references public.products(id, organization_id) on delete cascade,
  unique (storage_bucket, storage_path)
);

alter table public.products enable row level security;
alter table public.product_assets enable row level security;
create policy "Organization members can manage products" on public.products for all to authenticated
  using ((select public.is_organization_member(organization_id)))
  with check ((select public.is_organization_member(organization_id)));
create policy "Organization members can manage product assets" on public.product_assets for all to authenticated
  using ((select public.is_organization_member(organization_id)))
  with check ((select public.is_organization_member(organization_id)));
grant select, insert, update, delete on public.products, public.product_assets to authenticated;
grant all on public.products, public.product_assets to service_role;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-assets', 'product-assets', false, 10485760, array['image/png','image/jpeg','image/webp'])
on conflict (id) do update set public=false, file_size_limit=excluded.file_size_limit, allowed_mime_types=excluded.allowed_mime_types;

create policy "Organization members can read product assets" on storage.objects for select to authenticated
  using (bucket_id='product-assets' and (select public.is_organization_member((storage.foldername(name))[1]::uuid)));

alter table public.content_items
  add column creative_mode text not null default 'standard' check (creative_mode in ('standard','product')),
  add column selected_product_id uuid,
  add column product_selection_confirmed boolean not null default false,
  add constraint content_items_selected_product_fk foreign key (selected_product_id, organization_id)
    references public.products(id, organization_id) on delete set null;

create index products_brand_active_idx on public.products(brand_id, is_active, created_at);
create index content_items_product_idx on public.content_items(selected_product_id) where selected_product_id is not null;

create or replace function public.create_weekly_content_plan(p_brand_id uuid,p_starts_on date,p_strategy_summary text,p_strategy_inputs jsonb,p_items jsonb,p_replace boolean default false) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_brand public.brands;v_plan_id uuid;v_item jsonb;v_ends_on date:=p_starts_on+6;v_version integer;
begin
  select * into v_brand from public.brands where id=p_brand_id for update;
  if v_brand.id is null or not public.is_organization_member(v_brand.organization_id) then raise exception 'Brand unavailable' using errcode='42501';end if;
  if p_starts_on is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 21 then raise exception 'Invalid weekly plan' using errcode='22023';end if;
  select id into v_plan_id from public.content_plans where brand_id=p_brand_id and starts_on=p_starts_on and ends_on=v_ends_on and status in('draft','ready','active') order by version desc limit 1;
  if v_plan_id is not null and not p_replace then return v_plan_id;end if;
  if exists(select 1 from jsonb_array_elements(p_items)item where(item->>'planned_for')::date not between p_starts_on and v_ends_on or coalesce(btrim(item->>'working_title'),'')='' or coalesce(jsonb_array_length(item->'platform_targets'),0)=0 or not exists(select 1 from public.content_pillars cp where cp.id=(item->>'content_pillar_id')::uuid and cp.brand_id=p_brand_id and cp.is_active) or (coalesce(item->>'creative_mode','standard')='product' and not exists(select 1 from public.products p where p.id=(item->>'selected_product_id')::uuid and p.brand_id=p_brand_id and p.is_active))) then raise exception 'Invalid weekly plan item' using errcode='22023';end if;
  select coalesce(max(version),0)+1 into v_version from public.content_plans where brand_id=p_brand_id and starts_on=p_starts_on and ends_on=v_ends_on;
  if v_plan_id is not null then update public.content_plans set status='archived' where id=v_plan_id;end if;
  insert into public.content_plans(organization_id,brand_id,starts_on,ends_on,status,strategy_summary,strategy_inputs,version,created_by) values(v_brand.organization_id,p_brand_id,p_starts_on,v_ends_on,'ready',p_strategy_summary,coalesce(p_strategy_inputs,'{}'),v_version,auth.uid()) returning id into v_plan_id;
  for v_item in select value from jsonb_array_elements(p_items) loop
    insert into public.content_items(organization_id,brand_id,content_plan_id,content_pillar_id,planned_for,proposed_publish_at,platform_targets,format,archetype_key,working_title,hook,concept,creative_direction,call_to_action,risk_level,creative_mode,selected_product_id,product_selection_confirmed,created_by)
    values(v_brand.organization_id,p_brand_id,v_plan_id,(v_item->>'content_pillar_id')::uuid,(v_item->>'planned_for')::date,(v_item->>'proposed_publish_at')::timestamptz,array(select jsonb_array_elements_text(v_item->'platform_targets'))::public.social_platform[],(v_item->>'format')::public.content_format,v_item->>'archetype_key',v_item->>'working_title',v_item->>'hook',v_item->>'concept',v_item->>'creative_direction',v_item->>'call_to_action',(v_item->>'risk_level')::public.risk_level,coalesce(v_item->>'creative_mode','standard'),nullif(v_item->>'selected_product_id','')::uuid,coalesce((v_item->>'product_selection_confirmed')::boolean,false),auth.uid());
  end loop;return v_plan_id;
end;$$;

-- Standard and product workers must never race for the same queue row.
create or replace function public.claim_next_standard_generation_job(p_worker_id text, p_lease_seconds integer default 300)
returns public.generation_jobs language plpgsql security definer set search_path='' as $$
declare job public.generation_jobs;
begin
  if coalesce(length(btrim(p_worker_id)),0)=0 or p_lease_seconds not between 15 and 3600 then raise exception 'Invalid worker lease' using errcode='22023'; end if;
  update public.generation_jobs set state=case when attempt<max_attempts then 'retrying'::public.job_state else 'failed'::public.job_state end,lease_owner=null,lease_expires_at=null,next_run_at=now(),error_code='lease_expired',error_message='The previous worker lease expired.' where state in ('running','waiting_external') and lease_expires_at<=now() and coalesce(input->>'pipeline','')<>'product_reference_image';
  select * into job from public.generation_jobs
  where state in ('queued','retrying') and next_run_at<=now() and attempt<max_attempts
    and coalesce(input->>'pipeline','') <> 'product_reference_image'
  order by next_run_at,created_at for update skip locked limit 1;
  if job.id is null then return null; end if;
  update public.generation_jobs set state='running',lease_owner=p_worker_id,lease_expires_at=now()+make_interval(secs=>p_lease_seconds),attempt=attempt+1,started_at=coalesce(started_at,now()),error_code=null,error_message=null where id=job.id returning * into job;
  return job;
end; $$;

create or replace function public.claim_next_product_generation_job(p_worker_id text, p_lease_seconds integer default 300)
returns public.generation_jobs language plpgsql security definer set search_path='' as $$
declare job public.generation_jobs;
begin
  if coalesce(length(btrim(p_worker_id)),0)=0 or p_lease_seconds not between 15 and 3600 then raise exception 'Invalid worker lease' using errcode='22023'; end if;
  update public.generation_jobs set state=case when attempt<max_attempts then 'retrying'::public.job_state else 'failed'::public.job_state end,lease_owner=null,lease_expires_at=null,next_run_at=now(),error_code='lease_expired',error_message='The previous product worker lease expired.' where state in ('running','waiting_external') and lease_expires_at<=now() and input->>'pipeline'='product_reference_image';
  select * into job from public.generation_jobs
  where state in ('queued','retrying') and next_run_at<=now() and attempt<max_attempts
    and input->>'pipeline' = 'product_reference_image'
  order by next_run_at,created_at for update skip locked limit 1;
  if job.id is null then return null; end if;
  update public.generation_jobs set state='running',lease_owner=p_worker_id,lease_expires_at=now()+make_interval(secs=>p_lease_seconds),attempt=attempt+1,started_at=coalesce(started_at,now()),error_code=null,error_message=null where id=job.id returning * into job;
  return job;
end; $$;

revoke all on function public.claim_next_standard_generation_job(text,integer), public.claim_next_product_generation_job(text,integer) from public,anon,authenticated;
grant execute on function public.claim_next_standard_generation_job(text,integer), public.claim_next_product_generation_job(text,integer) to service_role;

select cron.unschedule('rithena-product-generation-worker') where exists (select 1 from cron.job where jobname='rithena-product-generation-worker');
select cron.schedule('rithena-product-generation-worker','* * * * *',$worker$
  select net.http_post(url:=secrets.worker_url,headers:=jsonb_build_object('Authorization','Bearer '||secrets.cron_secret,'Content-Type','application/json'),body:='{}'::jsonb,timeout_milliseconds:=120000)
  from (select max(decrypted_secret) filter(where name='rithena_product_worker_url') worker_url,max(decrypted_secret) filter(where name='rithena_cron_secret') cron_secret from vault.decrypted_secrets) secrets
  where secrets.worker_url is not null and secrets.cron_secret is not null;
$worker$);
