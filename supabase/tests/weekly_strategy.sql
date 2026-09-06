begin;

insert into auth.users(id) values
  ('10000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-000000000002');

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000001';
set local role = authenticated;

insert into public.organizations(id,name,slug,created_by) values
  ('20000000-0000-0000-0000-000000000001','Strategy test','strategy-test','10000000-0000-0000-0000-000000000001');
insert into public.brands(id,organization_id,name,slug,created_by,onboarding_completed_at) values
  ('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','Test brand','test-brand','10000000-0000-0000-0000-000000000001',now());
insert into public.content_pillars(id,organization_id,brand_id,name,target_percentage) values
  ('40000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001','Education',60),
  ('40000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001','Proof',40);

do $$
declare first_id uuid; retry_id uuid;
begin
  first_id := public.create_weekly_content_plan(
    '30000000-0000-0000-0000-000000000001','2026-09-07','Test week','{"timezone":"America/Toronto"}',
    '[{"content_pillar_id":"40000000-0000-0000-0000-000000000001","planned_for":"2026-09-07","proposed_publish_at":"2026-09-07T13:15:00Z","platform_targets":["linkedin"],"format":"carousel","archetype_key":"mini_tutorial","working_title":"A useful guide","hook":"Start here","concept":"Confirmed knowledge only","creative_direction":"Editorial","call_to_action":"Save this guide","risk_level":"low"}]'
  );
  retry_id := public.create_weekly_content_plan(
    '30000000-0000-0000-0000-000000000001','2026-09-07','Ignored retry','{}',
    '[{"content_pillar_id":"40000000-0000-0000-0000-000000000002","planned_for":"2026-09-08","proposed_publish_at":"2026-09-08T15:30:00Z","platform_targets":["instagram"],"format":"image","archetype_key":"pov","working_title":"Do not insert","hook":"Retry","concept":"Retry","creative_direction":"Editorial","call_to_action":"Follow","risk_level":"low"}]'
  );
  if first_id <> retry_id then raise exception 'retry created a different plan'; end if;
  if (select count(*) from public.content_items where content_plan_id=first_id) <> 1 then raise exception 'retry duplicated content'; end if;
  if (select proposed_publish_at from public.content_items where content_plan_id=first_id) <> '2026-09-07T13:15:00Z'::timestamptz then raise exception 'proposed time was not persisted'; end if;
end $$;

do $$
declare item_id uuid; moved public.content_items;
begin
  select ci.id into item_id from public.content_items ci join public.content_plans cp on cp.id=ci.content_plan_id
    where cp.brand_id='30000000-0000-0000-0000-000000000001' and cp.starts_on='2026-09-07' and cp.status='ready';
  moved := public.reschedule_content_plan_item(item_id,1,'2026-09-10','2026-09-10T16:15:00Z');
  if moved.planned_for <> '2026-09-10' or moved.proposed_publish_at <> '2026-09-10T16:15:00Z' or moved.content_revision <> 2 then
    raise exception 'reschedule did not persist or bump revision';
  end if;
  begin
    perform public.reschedule_content_plan_item(item_id,1,'2026-09-11','2026-09-11T16:15:00Z');
    raise exception 'stale revision unexpectedly succeeded';
  exception when serialization_failure then null;
  end;
  begin
    perform public.reschedule_content_plan_item(item_id,2,'2026-09-20','2026-09-20T16:15:00Z');
    raise exception 'out-of-week move unexpectedly succeeded';
  exception when invalid_parameter_value then null;
  end;
end $$;

do $$
declare replacement uuid;
begin
  replacement := public.create_weekly_content_plan(
    '30000000-0000-0000-0000-000000000001','2026-09-07','Better week','{"plannerVersion":2}',
    '[{"content_pillar_id":"40000000-0000-0000-0000-000000000002","planned_for":"2026-09-12","proposed_publish_at":"2026-09-12T15:30:00Z","platform_targets":["instagram"],"format":"image","archetype_key":"pov","working_title":"A distinct replacement","hook":"A better hook","concept":"A better brand-grounded concept","creative_direction":"Editorial","call_to_action":"Follow","risk_level":"low"}]', true
  );
  if (select version from public.content_plans where id=replacement) <> 2 then raise exception 'replacement version was not incremented'; end if;
  if (select count(*) from public.content_plans where brand_id='30000000-0000-0000-0000-000000000001' and starts_on='2026-09-07' and status='archived') <> 1 then raise exception 'previous plan was not archived'; end if;
  if (select count(*) from public.content_plans where brand_id='30000000-0000-0000-0000-000000000001' and starts_on='2026-09-07' and status='ready') <> 1 then raise exception 'replacement was not made current'; end if;
end $$;

set local request.jwt.claim.sub = '10000000-0000-0000-0000-000000000002';
do $$ begin
  perform public.create_weekly_content_plan('30000000-0000-0000-0000-000000000001','2026-09-14','Cross tenant','{}','[]');
  raise exception 'cross-tenant plan unexpectedly succeeded';
exception when insufficient_privilege then null;
end $$;

rollback;
