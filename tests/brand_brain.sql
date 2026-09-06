\set ON_ERROR_STOP on
begin;
insert into auth.users(id) values('00000000-0000-4000-8000-000000000001'),('00000000-0000-4000-8000-000000000002');
insert into public.organizations(id,name,slug,created_by) values('10000000-0000-4000-8000-000000000001','NOVA','nova','00000000-0000-4000-8000-000000000001');
insert into public.brands(id,organization_id,name,slug) values('20000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','NOVA','nova');
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
do $$declare p jsonb := '{"name":"NOVA Coffee","description":"A neighborhood cafe","websiteUrl":"https://example.com","timezone":"America/Toronto","audience":"Neighbors","voiceExamples":["A slower morning"],"bannedPhrases":[],"products":["Coffee"],"personalities":["Warm"],"visual":{"colors":["#131316"]},"goals":["educate"],"frequency":"custom","postsPerWeek":4,"pillars":[{"name":"Education","percentage":100}]}'; brand uuid:='20000000-0000-4000-8000-000000000001'; fact uuid:='30000000-0000-4000-8000-000000000001'; f jsonb; revision integer;
begin
  revision:=public.save_brand_brain(brand,1,p);
  if revision<>2 or (select name from public.brands where id=brand)<>'NOVA Coffee' then raise exception 'Brand not saved'; end if;
  if (select value from public.brand_preferences where brand_id=brand and category='audience')<>'"Neighbors"'::jsonb then raise exception 'Planning input missing'; end if;
  begin perform public.save_brand_brain(brand,1,p);raise exception 'Stale save accepted';exception when serialization_failure then null;end;
  begin perform public.save_brand_brain(brand,2,jsonb_set(p,'{pillars,0,percentage}','90'));raise exception 'Bad total accepted';exception when invalid_parameter_value then null;end;
  f:=public.save_brand_fact(brand,fact,0,'Roasts coffee',false,'https://example.com/about');
  if f->>'verification_status'<>'unverified' then raise exception 'New fact auto verified';end if;
  f:=public.save_brand_fact(brand,fact,(f->>'fact_revision')::integer,'Roasts coffee',true,null);
  if f->>'verification_status'<>'user_confirmed' or f->>'confirmed_by' is null then raise exception 'Confirmation missing actor';end if;
  begin update public.brand_facts set verification_status='verified' where id=fact;raise exception 'Direct trust write accepted';exception when insufficient_privilege then null;end;
  begin perform public.save_brand_fact(brand,fact,1,'Other claim',true,null);raise exception 'Stale confirmation accepted';exception when serialization_failure then null;end;
  f:=public.save_brand_fact(brand,fact,(f->>'fact_revision')::integer,'Sells coffee',false,'https://attacker.example');
  if f->>'verification_status'<>'unverified' or f->>'source_url'<>'https://example.com/about' then raise exception 'Edit did not preserve provenance/reset trust';end if;
  perform public.save_brand_brain(brand,2,p);
  if exists(select 1 from public.brand_facts where verification_status<>'unverified') then raise exception 'Preference save verified facts';end if;
end$$;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000002',true);
do $$begin
  if exists(select 1 from public.brands) or exists(select 1 from public.brand_facts) then raise exception 'Cross-tenant read';end if;
  begin perform public.save_brand_brain('20000000-0000-4000-8000-000000000001',3,'{}');raise exception 'Cross-tenant save accepted';exception when insufficient_privilege then null;end;
  begin perform public.save_brand_fact('20000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001',4,'Malicious',true,null);raise exception 'Cross-tenant confirmation accepted';exception when insufficient_privilege then null;end;
end$$;
rollback;
\echo 'PASS Brand Brain: persisted planning input, revision conflict, pillar totals, exact fact confirmation, immutable provenance, trust reset and tenant isolation'
