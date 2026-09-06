\set ON_ERROR_STOP on
begin;
insert into auth.users(id) values ('00000000-0000-4000-8000-000000000051'),('00000000-0000-4000-8000-000000000052');
insert into public.organizations(id,name,slug,created_by) values
 ('10000000-0000-4000-8000-000000000051','Instagram Test','instagram-test','00000000-0000-4000-8000-000000000051'),
 ('10000000-0000-4000-8000-000000000052','Other','instagram-other','00000000-0000-4000-8000-000000000052');
insert into public.brands(id,organization_id,name,slug) values
 ('20000000-0000-4000-8000-000000000051','10000000-0000-4000-8000-000000000051','NOVA Coffee','nova');
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000051',true);
do $$begin
 begin perform public.instagram_connection_command('due',null,null); raise exception 'Client can run service command'; exception when insufficient_privilege then null; end;
 begin perform 1 from private.instagram_credentials; raise exception 'Client can read credentials'; exception when insufficient_privilege then null; end;
 begin perform 1 from private.instagram_attempts; raise exception 'Client can read attempts'; exception when insufficient_privilege then null; end;
end $$;
reset role;
set local role service_role;
do $$declare
 u uuid := '00000000-0000-4000-8000-000000000051'; b uuid := '20000000-0000-4000-8000-000000000051';
 attempt_id uuid := '30000000-0000-4000-8000-000000000051';
 data jsonb := jsonb_build_object('id',attempt_id,'stateHash',repeat('a',64),'browserHash',repeat('b',64));
 staged jsonb; claimed jsonb; connection uuid; preview jsonb;
begin
 begin perform public.instagram_connection_command('start','00000000-0000-4000-8000-000000000052',b,data); raise exception 'Cross-tenant start accepted'; exception when insufficient_privilege then null; end;
 perform public.instagram_connection_command('start',u,b,data);
 begin perform public.instagram_connection_command('consume',u,b,data || jsonb_build_object('stateHash',repeat('c',64))); raise exception 'Wrong state accepted'; exception when serialization_failure then null; end;
 begin perform public.instagram_connection_command('consume',u,b,data || jsonb_build_object('browserHash',repeat('c',64))); raise exception 'Wrong browser accepted'; exception when serialization_failure then null; end;
 claimed := public.instagram_connection_command('consume',u,b,data);
 connection := (claimed->>'connectionId')::uuid;
 begin perform public.instagram_connection_command('consume',u,b,data); raise exception 'Replay accepted'; exception when serialization_failure then null; end;
 staged := data || jsonb_build_object('destination',jsonb_build_object('id','123456789012345678','username','nova'), 'ciphertext','v1.test.encrypted.payload',
  'issuedAt',now(),'expiresAt',now()+interval '60 days','scopes',jsonb_build_array('instagram_business_basic','instagram_business_content_publish'));
 begin perform public.instagram_connection_command('stage',u,b,staged || '{"scopes":["instagram_business_basic"]}'); raise exception 'Missing publish scope accepted'; exception when raise_exception then if sqlerrm='Missing publish scope accepted' then raise; end if; end;
 perform public.instagram_connection_command('stage',u,b,staged);
 preview := public.instagram_connection_command('preview',u,b,data);
 if preview->>'username'<>'nova' or preview ? 'ciphertext' then raise exception 'Unsafe preview'; end if;
 perform public.instagram_connection_command('confirm',u,b,data);
 if not exists(select 1 from public.social_connections where id=connection and status='connected' and provider_account_id='123456789012345678') then raise exception 'Connection not persisted'; end if;
 begin perform public.instagram_connection_command('confirm',u,b,data); raise exception 'Confirm replay accepted'; exception when serialization_failure then null; end;
 claimed := public.instagram_connection_command('claim',u,b,jsonb_build_object('connectionId',connection));
 begin perform public.instagram_connection_command('claim',u,b,jsonb_build_object('connectionId',connection)); raise exception 'Lease theft accepted'; exception when serialization_failure then null; end;
 begin perform public.instagram_connection_command('finish',u,b,claimed || jsonb_build_object('connectionId',connection,'leaseId',gen_random_uuid(),'status','connected')); raise exception 'Wrong lease completion accepted'; exception when serialization_failure then null; end;
 perform public.instagram_connection_command('finish',u,b,claimed || jsonb_build_object('connectionId',connection,'status','expired','errorCode','expired','errorMessage','Reconnect your account.'));
 if not exists(select 1 from public.social_connections where id=connection and status='expired') then raise exception 'Expiry not visible'; end if;
 -- Reconnect stages the same destination; a different account is rejected.
 data := data || jsonb_build_object('id',gen_random_uuid(),'connectionId',connection);
 perform public.instagram_connection_command('start',u,b,data);
 perform public.instagram_connection_command('consume',u,b,data);
 staged := staged || data;
 begin perform public.instagram_connection_command('stage',u,b,staged || '{"destination":{"id":"different","username":"other"}}'); raise exception 'Wrong reconnect destination accepted'; exception when invalid_parameter_value then null; end;
 perform public.instagram_connection_command('stage',u,b,staged);
 claimed := public.instagram_connection_command('claim',u,b,jsonb_build_object('connectionId',connection));
 perform public.instagram_connection_command('confirm',u,b,data);
 begin perform public.instagram_connection_command('finish',u,b,claimed || jsonb_build_object('connectionId',connection,'status','revoked')); raise exception 'Stale check overwrote reconnect'; exception when serialization_failure then null; end;
 if (select count(*) from public.social_connections where brand_id=b)<>1 then raise exception 'Reconnect duplicated connection'; end if;
 claimed := public.instagram_connection_command('claim',u,b,jsonb_build_object('connectionId',connection));
 perform public.instagram_connection_command('start',u,b,data);
 perform public.instagram_connection_command('disconnect',u,b,jsonb_build_object('connectionId',connection));
 begin perform public.instagram_connection_command('finish',u,b,claimed || jsonb_build_object('connectionId',connection,'status','connected')); raise exception 'Refresh restored disconnect'; exception when serialization_failure then null; end;
 begin perform public.instagram_connection_command('consume',u,b,data); raise exception 'Disconnect did not cancel OAuth'; exception when serialization_failure then null; end;
 if not exists(select 1 from public.social_connections where id=connection and credentials_reference is null and last_error_code='disconnected') then raise exception 'Disconnect incomplete'; end if;
end $$;
reset role;
do $$begin
 if exists(select 1 from private.instagram_credentials) or exists(select 1 from private.instagram_attempts) then raise exception 'Secrets remained after disconnect'; end if;
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000052',true);
do $$begin if exists(select 1 from public.social_connections) then raise exception 'Cross-tenant connection exposed'; end if; end $$;
rollback;
