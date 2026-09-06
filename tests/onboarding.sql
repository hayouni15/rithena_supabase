\set ON_ERROR_STOP on
begin;
insert into auth.users(id) values('00000000-0000-4000-8000-000000000001'),('00000000-0000-4000-8000-000000000002');
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
select public.save_onboarding_draft('{"step":3,"goals":["educate"]}',0);
do $$begin
  begin perform public.save_onboarding_draft('{"step":4}',0); raise exception 'stale write accepted'; exception when serialization_failure then null; end;
end$$;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000002',true);
do $$begin if exists(select 1 from public.onboarding_drafts) then raise exception 'Draft leaked across accounts'; end if; end$$;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
do $$
declare p jsonb := '{"organizationName":"NOVA workspace","timezone":"America/Toronto","websiteUrl":"https://example.com","analysis":{"companyName":"NOVA Coffee","description":"Coffee","factualClaims":[{"claim":"Roasts coffee","confidence":0.8}]},"goals":["educate"],"channels":["Instagram"],"creativePersonalities":["Warm"],"frequency":"custom","customPostsPerWeek":4,"autopilotMode":"review_everything"}'; a uuid; b uuid;
begin
  begin perform public.complete_onboarding(jsonb_set(p,'{timezone}','"Fake/Zone"')); raise exception 'timezone accepted'; exception when invalid_parameter_value then null; end;
  begin perform public.complete_onboarding(jsonb_set(p,'{customPostsPerWeek}','0')); raise exception 'zero frequency accepted'; exception when invalid_parameter_value then null; end;
  -- Invalid goal fails late, after the organization and brand would have been inserted.
  begin perform public.complete_onboarding(jsonb_set(p,'{goals}','["invalid"]')); raise exception 'invalid goal accepted'; exception when invalid_text_representation then null; end;
  if exists(select 1 from public.organizations) then raise exception 'Transaction did not roll back'; end if;
  if not exists(select 1 from public.onboarding_drafts) then raise exception 'Failure lost draft'; end if;
  a := public.complete_onboarding(p); b := public.complete_onboarding(p);
  if a <> b or (select count(*) from public.brands) <> 1 or (select count(*) from public.organizations) <> 1 then raise exception 'Retry duplicated setup'; end if;
  if exists(select 1 from public.onboarding_drafts) then raise exception 'Completed draft remains'; end if;
  if exists(select 1 from public.brand_facts where verification_status <> 'unverified') then raise exception 'Facts auto verified'; end if;
end$$;
rollback;
\echo 'PASS onboarding: account isolation, optimistic conflict, invalid settings, rollback, retry, fact trust'
