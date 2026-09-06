-- Provider credentials and OAuth attempts are never accessible through the client API.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table if not exists private.instagram_attempts (
 id uuid primary key, user_id uuid not null references auth.users(id) on delete cascade,
 brand_id uuid not null references public.brands(id) on delete cascade,
 connection_id uuid not null, reconnect boolean not null,
 state_hash text not null unique, browser_hash text not null,
 phase text not null default 'pending' check (phase in ('pending','exchanging','ready')),
 expires_at timestamptz not null default now() + interval '10 minutes',
 destination jsonb, ciphertext text, issued_at timestamptz, token_expires_at timestamptz, scopes text[]
);
create table if not exists private.instagram_credentials (
 connection_id uuid primary key references public.social_connections(id) on delete cascade,
 ciphertext text not null, issued_at timestamptz not null,
 revision uuid not null default gen_random_uuid(), lease_id uuid, lease_until timestamptz
);

-- A failed/manual deployment may have created one of these private tables
-- without recording the migration. Retrying is safe only when that relation has
-- the shape this migration expects; otherwise stop before installing functions
-- against an unknown credential schema.
do $$
declare
 attempts_columns text[] := array[
  'brand_id','browser_hash','ciphertext','connection_id','destination','expires_at','id',
  'issued_at','phase','reconnect','scopes','state_hash','token_expires_at','user_id'
 ];
 credentials_columns text[] := array[
  'ciphertext','connection_id','issued_at','lease_id','lease_until','revision'
 ];
 actual text[];
begin
 if (select relkind from pg_catalog.pg_class where oid='private.instagram_attempts'::regclass) not in ('r','p') then
  raise exception 'private.instagram_attempts exists but is not a table';
 end if;
 select array_agg(column_name order by column_name) into actual
 from information_schema.columns where table_schema='private' and table_name='instagram_attempts';
 if actual is distinct from attempts_columns then
  raise exception 'private.instagram_attempts has an incompatible shape; expected columns %, found %', attempts_columns, actual;
 end if;

 if (select relkind from pg_catalog.pg_class where oid='private.instagram_credentials'::regclass) not in ('r','p') then
  raise exception 'private.instagram_credentials exists but is not a table';
 end if;
 select array_agg(column_name order by column_name) into actual
 from information_schema.columns where table_schema='private' and table_name='instagram_credentials';
 if actual is distinct from credentials_columns then
  raise exception 'private.instagram_credentials has an incompatible shape; expected columns %, found %', credentials_columns, actual;
 end if;
end $$;
alter table private.instagram_attempts enable row level security;
alter table private.instagram_credentials enable row level security;
revoke all on all tables in schema private from public, anon, authenticated;

-- One service-only entry point keeps each operation transactional. User operations
-- require current membership even though the caller uses server credentials.
create or replace function public.instagram_connection_command(p_action text,p_user uuid,p_brand uuid,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 b public.brands; a private.instagram_attempts; c public.social_connections;
 secret private.instagram_credentials; result jsonb; connection uuid;
begin
 if p_action = 'due' then
  delete from private.instagram_attempts where expires_at <= now();
  return coalesce((select jsonb_agg(x) from (
   select s.id,s.brand_id from public.social_connections s join private.instagram_credentials k on k.connection_id=s.id
   where s.platform='instagram' and s.status in ('connected','error')
   and (s.last_validated_at is null or s.last_validated_at < now()-interval '12 hours')
   and (k.lease_until is null or k.lease_until < now()) order by s.last_validated_at nulls first limit 12
  ) x),'[]');
 end if;
 select * into b from public.brands where id=p_brand for update;
 if b.id is null then raise exception 'Brand unavailable' using errcode='42501'; end if;
 if p_user is null then
  if p_action not in ('claim','finish') then raise exception 'User required' using errcode='42501'; end if;
 elsif not exists(select 1 from public.organization_members where organization_id=b.organization_id and user_id=p_user) then
  raise exception 'Membership required' using errcode='42501';
 end if;
 delete from private.instagram_attempts where brand_id=b.id and expires_at <= now();
 if p_action='start' then
  if length(p_data->>'stateHash') <> 64 or length(p_data->>'browserHash') <> 64 then raise exception 'Invalid state'; end if;
  connection := coalesce(nullif(p_data->>'connectionId','')::uuid,gen_random_uuid());
  if p_data->>'connectionId' is not null then
   select * into c from public.social_connections where id=connection and brand_id=b.id and platform='instagram';
   if c.id is null then raise exception 'Connection unavailable' using errcode='42501'; end if;
  end if;
  delete from private.instagram_attempts where user_id=p_user and brand_id=b.id;
  insert into private.instagram_attempts(id,user_id,brand_id,connection_id,reconnect,state_hash,browser_hash)
   values((p_data->>'id')::uuid,p_user,b.id,connection,c.id is not null,p_data->>'stateHash',p_data->>'browserHash') returning * into a;
  return jsonb_build_object('id',a.id);
 elsif p_action in ('consume','stage','preview','confirm','cancel') then
  select * into a from private.instagram_attempts where id=(p_data->>'id')::uuid and user_id=p_user and brand_id=b.id
   and browser_hash=p_data->>'browserHash' and expires_at>now() for update;
  if a.id is null then raise exception 'Connection attempt expired. Start again.' using errcode='40001'; end if;
  if p_action='cancel' then
   delete from private.instagram_attempts where id=a.id; return '{}';
  elsif p_action='consume' then
   if a.phase <> 'pending' or a.state_hash <> p_data->>'stateHash' then raise exception 'Invalid or used state' using errcode='40001'; end if;
   update private.instagram_attempts set phase='exchanging' where id=a.id;
   return jsonb_build_object('connectionId',a.connection_id,'organizationId',b.organization_id);
  elsif p_action='stage' then
   if a.phase <> 'exchanging' then raise exception 'Invalid attempt phase' using errcode='40001'; end if;
   if not (p_data->'scopes' @> '["instagram_business_basic","instagram_business_content_publish"]'::jsonb)
    or p_data->>'ciphertext' is null or p_data->'destination'->>'id' is null
    or (p_data->>'expiresAt')::timestamptz <= now() then raise exception 'Incomplete authorization'; end if;
   if a.reconnect and not exists(select 1 from public.social_connections where id=a.connection_id and provider_account_id=p_data->'destination'->>'id') then
    raise exception 'Reconnect the same Instagram account' using errcode='22023';
   end if;
   update private.instagram_attempts set phase='ready',destination=p_data->'destination',ciphertext=p_data->>'ciphertext',
    issued_at=(p_data->>'issuedAt')::timestamptz,token_expires_at=(p_data->>'expiresAt')::timestamptz,
    scopes=array(select jsonb_array_elements_text(p_data->'scopes')) where id=a.id;
   return '{}';
  elsif p_action='preview' then
   if a.phase <> 'ready' then raise exception 'Authorization incomplete' using errcode='40001'; end if;
   return jsonb_build_object('id',a.id,'username',a.destination->>'username','reconnect',a.reconnect);
  else
   if a.phase <> 'ready' or a.token_expires_at<=now() then raise exception 'Authorization expired' using errcode='40001'; end if;
   if not a.reconnect and exists(select 1 from public.social_connections where brand_id=b.id and platform='instagram' and provider_account_id=a.destination->>'id') then
    raise exception 'This account already exists. Use Reconnect.' using errcode='23505';
   end if;
   insert into public.social_connections(id,organization_id,brand_id,platform,provider_account_id,provider_account_name,provider_account_handle,status,scopes,credentials_reference,token_expires_at,last_validated_at,connected_by)
   values(a.connection_id,b.organization_id,b.id,'instagram',a.destination->>'id',a.destination->>'username',a.destination->>'username','connected',a.scopes,a.connection_id::text,a.token_expires_at,now(),p_user)
   on conflict(id) do update set provider_account_name=excluded.provider_account_name,provider_account_handle=excluded.provider_account_handle,
    status='connected',scopes=excluded.scopes,credentials_reference=excluded.credentials_reference,token_expires_at=excluded.token_expires_at,
    last_validated_at=now(),last_error_code=null,last_error_message=null,connected_by=p_user;
   insert into private.instagram_credentials(connection_id,ciphertext,issued_at) values(a.connection_id,a.ciphertext,a.issued_at)
   on conflict(connection_id) do update set ciphertext=excluded.ciphertext,issued_at=excluded.issued_at,revision=gen_random_uuid(),lease_id=null,lease_until=null;
   delete from private.instagram_attempts where brand_id=b.id;
   return '{}';
  end if;
 elsif p_action in ('disconnect','claim','finish') then
  select * into c from public.social_connections where id=(p_data->>'connectionId')::uuid and brand_id=b.id and platform='instagram' for update;
  if c.id is null then raise exception 'Connection unavailable' using errcode='42501'; end if;
  if p_action='disconnect' then
   delete from private.instagram_credentials where connection_id=c.id;
   delete from private.instagram_attempts where brand_id=b.id;
   update public.social_connections set status='revoked',credentials_reference=null,scopes='{}',token_expires_at=null,
    last_error_code='disconnected',last_error_message='Disconnected from Rithena. Reconnect to use this account.' where id=c.id;
   return '{}';
  end if;
  select * into secret from private.instagram_credentials where connection_id=c.id for update;
  if secret.connection_id is null then raise exception 'Reconnect this account' using errcode='40001'; end if;
  if p_action='claim' then
   if secret.lease_until>now() then raise exception 'Connection check already running' using errcode='40001'; end if;
   update private.instagram_credentials set lease_id=gen_random_uuid(),lease_until=now()+interval '2 minutes' where connection_id=c.id returning * into secret;
   return jsonb_build_object('ciphertext',secret.ciphertext,'issuedAt',secret.issued_at,'expiresAt',c.token_expires_at,
    'organizationId',b.organization_id,'accountId',c.provider_account_id,'revision',secret.revision,'leaseId',secret.lease_id);
  end if;
  if secret.revision <> (p_data->>'revision')::uuid or secret.lease_id is distinct from (p_data->>'leaseId')::uuid or secret.lease_until<=now() then
   raise exception 'Connection changed during check' using errcode='40001';
  end if;
  if p_data->>'status' not in ('connected','expired','revoked','error') then raise exception 'Invalid health'; end if;
  update public.social_connections set status=(p_data->>'status')::public.connection_status,last_validated_at=now(),
   last_error_code=p_data->>'errorCode',last_error_message=p_data->>'errorMessage',
   token_expires_at=coalesce((p_data->>'expiresAt')::timestamptz,token_expires_at),
   scopes=case when p_data->>'status'='connected' then array(select jsonb_array_elements_text(p_data->'scopes')) else scopes end
   where id=c.id;
  update private.instagram_credentials set ciphertext=coalesce(p_data->>'ciphertext',ciphertext),issued_at=coalesce((p_data->>'issuedAt')::timestamptz,issued_at),
   revision=gen_random_uuid(),lease_id=null,lease_until=null where connection_id=c.id;
  return '{}';
 end if;
 raise exception 'Unknown connection operation';
end $$;
revoke all on function public.instagram_connection_command(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.instagram_connection_command(text,uuid,uuid,jsonb) to service_role;
