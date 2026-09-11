begin;
select plan(7);

insert into auth.users(id) values('18001800-0000-4000-8000-000000000000');
set local request.jwt.claim.sub = '18001800-0000-4000-8000-000000000000';
set local role = authenticated;
insert into public.organizations(id,name,slug,created_by) values('18001800-0000-4000-8000-000000000001','Allowance Test','allowance-test','18001800-0000-4000-8000-000000000000');
update public.subscriptions set trial_started_at=now(),trial_ends_at=null
where organization_id='18001800-0000-4000-8000-000000000001';

select is((select plan_code from public.subscriptions where organization_id='18001800-0000-4000-8000-000000000001'),'free_trial','new organizations receive the free tier');
select ok((select trial_ends_at is null from public.subscriptions where organization_id='18001800-0000-4000-8000-000000000001'),'free access does not expire');

insert into public.generation_jobs(organization_id,type,provider,state) values('18001800-0000-4000-8000-000000000001','image','test','queued');
select is((select count(*)::integer from public.generation_jobs where organization_id='18001800-0000-4000-8000-000000000001'),1,'first preview is reserved');
select throws_ok($$insert into public.generation_jobs(organization_id,type,provider,state) values('18001800-0000-4000-8000-000000000001','video','test','queued')$$,'P0001','Your free creative preview has already been used','a second preview is rejected');
select lives_ok($$insert into public.generation_jobs(organization_id,type,provider,state) values('18001800-0000-4000-8000-000000000001','copy','test','queued')$$,'non-media work does not consume the preview');
select is((public.select_subscription_plan('18001800-0000-4000-8000-000000000001','managed')).plan_code,'managed','an owner can select a paid plan without Stripe');
select lives_ok($$insert into public.generation_jobs(organization_id,type,provider,state) values('18001800-0000-4000-8000-000000000001','video','test','queued')$$,'a paid plan removes the free-tier cap');

select * from finish();
rollback;
