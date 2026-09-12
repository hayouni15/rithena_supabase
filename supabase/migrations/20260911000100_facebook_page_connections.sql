create table private.facebook_attempts (
 id uuid primary key, user_id uuid not null references auth.users(id) on delete cascade,
 brand_id uuid not null references public.brands(id) on delete cascade,
 connection_id uuid not null, reconnect boolean not null,
 state_hash text not null unique, browser_hash text not null,
 phase text not null default 'pending' check (phase in ('pending','exchanging','ready','selected')),
 expires_at timestamptz not null default now() + interval '10 minutes',
 destination jsonb, ciphertext text, issued_at timestamptz, token_expires_at timestamptz, scopes text[]
);
create table private.facebook_credentials (
 connection_id uuid primary key references public.social_connections(id) on delete cascade,
 ciphertext text not null, issued_at timestamptz not null,
 revision uuid not null default gen_random_uuid(), lease_id uuid, lease_until timestamptz
);
alter table private.facebook_attempts enable row level security;
alter table private.facebook_credentials enable row level security;
revoke all on private.facebook_attempts, private.facebook_credentials from public,anon,authenticated;

create or replace function public.facebook_connection_command(p_action text,p_user uuid,p_brand uuid,p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 b public.brands; a private.facebook_attempts; c public.social_connections;
 secret private.facebook_credentials; connection uuid; selected jsonb;
begin
 if p_action='due' then
  delete from private.facebook_attempts where expires_at<=now();
  return coalesce((select jsonb_agg(x) from (
   select s.id,s.brand_id from public.social_connections s join private.facebook_credentials k on k.connection_id=s.id
   where s.platform='facebook' and s.status in ('connected','error')
   and (s.last_validated_at is null or s.last_validated_at<now()-interval '12 hours')
   and (k.lease_until is null or k.lease_until<now()) order by s.last_validated_at nulls first limit 12
  ) x),'[]');
 end if;
 select * into b from public.brands where id=p_brand for update;
 if b.id is null then raise exception 'Brand unavailable' using errcode='42501'; end if;
 if p_user is null then
  if p_action not in ('claim','finish') then raise exception 'User required' using errcode='42501'; end if;
 elsif not exists(select 1 from public.organization_members where organization_id=b.organization_id and user_id=p_user) then
  raise exception 'Membership required' using errcode='42501';
 end if;
 delete from private.facebook_attempts where brand_id=b.id and expires_at<=now();
 if p_action='start' then
  if length(p_data->>'stateHash')<>64 or length(p_data->>'browserHash')<>64 then raise exception 'Invalid state'; end if;
  connection:=coalesce(nullif(p_data->>'connectionId','')::uuid,gen_random_uuid());
  if p_data->>'connectionId' is not null then
   select * into c from public.social_connections where id=connection and brand_id=b.id and platform='facebook';
   if c.id is null then raise exception 'Connection unavailable' using errcode='42501'; end if;
  end if;
  delete from private.facebook_attempts where user_id=p_user and brand_id=b.id;
  insert into private.facebook_attempts(id,user_id,brand_id,connection_id,reconnect,state_hash,browser_hash)
   values((p_data->>'id')::uuid,p_user,b.id,connection,c.id is not null,p_data->>'stateHash',p_data->>'browserHash');
  return '{}';
 elsif p_action in ('consume','stage','preview','select','narrow','confirm','cancel') then
  select * into a from private.facebook_attempts where id=(p_data->>'id')::uuid and user_id=p_user and brand_id=b.id
   and browser_hash=p_data->>'browserHash' and expires_at>now() for update;
  if a.id is null then raise exception 'Connection attempt expired' using errcode='40001'; end if;
  if p_action='cancel' then delete from private.facebook_attempts where id=a.id; return '{}';
  elsif p_action='consume' then
   if a.phase<>'pending' or a.state_hash<>p_data->>'stateHash' then raise exception 'Invalid or used state' using errcode='40001'; end if;
   update private.facebook_attempts set phase='exchanging' where id=a.id;
   return jsonb_build_object('connectionId',a.connection_id,'organizationId',b.organization_id);
  elsif p_action='stage' then
   if a.phase<>'exchanging' then raise exception 'Invalid attempt phase' using errcode='40001'; end if;
   if not (p_data->'scopes' @> '["pages_show_list","pages_read_engagement","pages_manage_posts","read_insights"]'::jsonb)
    or p_data->>'ciphertext' is null or jsonb_array_length(p_data->'destination'->'pages')<1
    or (p_data->>'expiresAt')::timestamptz<=now() then raise exception 'Incomplete authorization'; end if;
   update private.facebook_attempts set phase='ready',destination=p_data->'destination',ciphertext=p_data->>'ciphertext',
    issued_at=(p_data->>'issuedAt')::timestamptz,token_expires_at=(p_data->>'expiresAt')::timestamptz,
    scopes=array(select jsonb_array_elements_text(p_data->'scopes')) where id=a.id;
   return '{}';
  elsif p_action='preview' then
   if a.phase not in ('ready','selected') then raise exception 'Authorization incomplete' using errcode='40001'; end if;
   return jsonb_build_object('id',a.id,'pages',a.destination->'pages','selectedPageId',a.destination->>'selectedPageId','reconnect',a.reconnect);
  elsif p_action='select' then
   if a.phase not in ('ready','selected') then raise exception 'Authorization incomplete' using errcode='40001'; end if;
   select value into selected from jsonb_array_elements(a.destination->'pages') where value->>'id'=p_data->>'pageId';
   if selected is null then raise exception 'Page unavailable' using errcode='22023'; end if;
   if a.reconnect and not exists(select 1 from public.social_connections where id=a.connection_id and provider_account_id=selected->>'id') then
    raise exception 'Reconnect the same Facebook Page' using errcode='22023';
   end if;
   update private.facebook_attempts set phase='selected',destination=jsonb_set(destination,'{selectedPageId}',to_jsonb(selected->>'id')) where id=a.id;
   return jsonb_build_object('ciphertext',a.ciphertext,'connectionId',a.connection_id,'organizationId',b.organization_id);
  elsif p_action='narrow' then
   if a.phase<>'selected' or p_data->>'ciphertext' is null then raise exception 'Page not selected' using errcode='40001'; end if;
   update private.facebook_attempts set ciphertext=p_data->>'ciphertext' where id=a.id;
   return '{}';
  else
   if a.phase<>'selected' or a.token_expires_at<=now() then raise exception 'Choose a Page first' using errcode='40001'; end if;
   select value into selected from jsonb_array_elements(a.destination->'pages') where value->>'id'=a.destination->>'selectedPageId';
   if not a.reconnect and exists(select 1 from public.social_connections where brand_id=b.id and platform='facebook' and provider_account_id=selected->>'id') then
    raise exception 'This Page already exists' using errcode='23505';
   end if;
   insert into public.social_connections(id,organization_id,brand_id,platform,provider_account_id,provider_account_name,provider_account_handle,status,scopes,credentials_reference,token_expires_at,last_validated_at,connected_by,metadata)
   values(a.connection_id,b.organization_id,b.id,'facebook',selected->>'id',selected->>'name',selected->>'name','connected',a.scopes,a.connection_id::text,a.token_expires_at,now(),p_user,jsonb_build_object('tasks',selected->'tasks'))
   on conflict(id) do update set provider_account_name=excluded.provider_account_name,provider_account_handle=excluded.provider_account_handle,
    status='connected',scopes=excluded.scopes,credentials_reference=excluded.credentials_reference,token_expires_at=excluded.token_expires_at,
    last_validated_at=now(),last_error_code=null,last_error_message=null,connected_by=p_user,metadata=excluded.metadata;
   insert into private.facebook_credentials(connection_id,ciphertext,issued_at) values(a.connection_id,a.ciphertext,a.issued_at)
   on conflict(connection_id) do update set ciphertext=excluded.ciphertext,issued_at=excluded.issued_at,revision=gen_random_uuid(),lease_id=null,lease_until=null;
   delete from private.facebook_attempts where id=a.id; return '{}';
  end if;
 elsif p_action in ('disconnect','claim','finish') then
  select * into c from public.social_connections where id=(p_data->>'connectionId')::uuid and brand_id=b.id and platform='facebook' for update;
  if c.id is null then raise exception 'Connection unavailable' using errcode='42501'; end if;
  if p_action='disconnect' then
   delete from private.facebook_credentials where connection_id=c.id;
   delete from private.facebook_attempts where brand_id=b.id;
   update public.social_connections set status='revoked',credentials_reference=null,scopes='{}',token_expires_at=null,last_error_code='disconnected',last_error_message='Disconnected from Rithena. Reconnect to use this Page.' where id=c.id;
   return '{}';
  end if;
  select * into secret from private.facebook_credentials where connection_id=c.id for update;
  if secret.connection_id is null then raise exception 'Reconnect this Page' using errcode='40001'; end if;
  if p_action='claim' then
   if secret.lease_until>now() then raise exception 'Connection check already running' using errcode='40001'; end if;
   update private.facebook_credentials set lease_id=gen_random_uuid(),lease_until=now()+interval '2 minutes' where connection_id=c.id returning * into secret;
   return jsonb_build_object('ciphertext',secret.ciphertext,'organizationId',b.organization_id,'accountId',c.provider_account_id,'revision',secret.revision,'leaseId',secret.lease_id);
  end if;
  if secret.revision<>(p_data->>'revision')::uuid or secret.lease_id is distinct from (p_data->>'leaseId')::uuid or secret.lease_until<=now() then raise exception 'Connection changed during check' using errcode='40001'; end if;
  if p_data->>'status' not in ('connected','expired','revoked','error') then raise exception 'Invalid health'; end if;
  update public.social_connections set status=(p_data->>'status')::public.connection_status,last_validated_at=now(),last_error_code=p_data->>'errorCode',last_error_message=p_data->>'errorMessage' where id=c.id;
  update private.facebook_credentials set revision=gen_random_uuid(),lease_id=null,lease_until=null where connection_id=c.id;
  return '{}';
 end if;
 raise exception 'Unknown connection operation';
end $$;
revoke all on function public.facebook_connection_command(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.facebook_connection_command(text,uuid,uuid,jsonb) to service_role;
