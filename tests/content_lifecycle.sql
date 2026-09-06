\set ON_ERROR_STOP on
begin;

insert into auth.users(id) values
  ('00000000-0000-4000-8000-000000000011'),
  ('00000000-0000-4000-8000-000000000012');
insert into public.organizations(id,name,slug,created_by) values
  ('10000000-0000-4000-8000-000000000011','Lifecycle Org','lifecycle-org','00000000-0000-4000-8000-000000000011'),
  ('10000000-0000-4000-8000-000000000012','Other Org','other-org','00000000-0000-4000-8000-000000000012');
insert into public.brands(id,organization_id,name,slug) values
  ('20000000-0000-4000-8000-000000000011','10000000-0000-4000-8000-000000000011','Lifecycle Brand','lifecycle-brand'),
  ('20000000-0000-4000-8000-000000000012','10000000-0000-4000-8000-000000000012','Other Brand','other-brand');
insert into public.content_items(id,organization_id,brand_id,format,working_title,status) values
  ('30000000-0000-4000-8000-000000000011','10000000-0000-4000-8000-000000000011','20000000-0000-4000-8000-000000000011','image','Lifecycle item','draft_plan');

set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000011',true);

do $$declare item public.content_items; approval public.approvals; rev integer;
begin
  begin insert into public.content_items(organization_id,brand_id,format,working_title,status) values
    ('10000000-0000-4000-8000-000000000011','20000000-0000-4000-8000-000000000011','image','Bypass item','published');
    raise exception 'Invalid initial status accepted';
  exception when invalid_parameter_value then null; end;
  begin update public.content_items set status='published' where id='30000000-0000-4000-8000-000000000011'; raise exception 'Direct status update accepted';
  exception when insufficient_privilege then null; end;
  begin perform public.transition_content_item('30000000-0000-4000-8000-000000000011','draft_plan',1,'published'); raise exception 'Invalid transition accepted';
  exception when invalid_parameter_value then null; end;

  item := public.transition_content_item('30000000-0000-4000-8000-000000000011','draft_plan',1,'planned');
  item := public.transition_content_item(item.id,'planned',item.content_revision,'generating');
  item := public.transition_content_item(item.id,'generating',item.content_revision,'qa');
  item := public.transition_content_item(item.id,'qa',item.content_revision,'ready_for_review');
  approval := public.decide_content_item(item.id,item.content_revision,'approved');
  if approval.content_revision <> item.content_revision or (select status from public.content_items where id=item.id) <> 'approved' then
    raise exception 'Approval did not bind and transition current revision';
  end if;

  rev := public.bump_content_revision(item.id,item.content_revision);
  begin perform public.transition_content_item(item.id,'approved',rev,'scheduled'); raise exception 'Stale approval scheduled';
  exception when invalid_parameter_value then null; end;
  begin perform public.bump_content_revision(item.id,item.content_revision); raise exception 'Stale revision accepted';
  exception when serialization_failure then null; end;
end$$;

select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000012',true);
do $$begin
  if exists(select 1 from public.content_items) or exists(select 1 from public.approvals) then raise exception 'Cross-organization data exposed'; end if;
  begin perform public.transition_content_item('30000000-0000-4000-8000-000000000011','approved',2,'scheduled'); raise exception 'Cross-organization transition accepted';
  exception when insufficient_privilege then null; end;
  begin perform public.decide_content_item('30000000-0000-4000-8000-000000000011',2,'approved'); raise exception 'Cross-organization approval accepted';
  exception when insufficient_privilege then null; end;
end$$;

reset role;
insert into public.generation_jobs(id,organization_id,brand_id,content_item_id,type,state,provider) values
  ('40000000-0000-4000-8000-000000000011','10000000-0000-4000-8000-000000000011','20000000-0000-4000-8000-000000000011','30000000-0000-4000-8000-000000000011','image','queued','test');

do $$declare job public.generation_jobs;
begin
  job := public.claim_generation_job('40000000-0000-4000-8000-000000000011','worker-a',60);
  if job.state <> 'running' or job.lease_owner <> 'worker-a' or job.attempt <> 1 then raise exception 'Job not claimed'; end if;
  begin perform public.claim_generation_job(job.id,'worker-b',60); raise exception 'Active lease stolen';
  exception when object_not_in_prerequisite_state then null; end;
  begin perform public.transition_generation_job(job.id,'worker-b','running','succeeded'); raise exception 'Wrong worker completed job';
  exception when insufficient_privilege then null; end;
  begin perform public.transition_generation_job(job.id,'worker-a','running','queued'); raise exception 'Invalid job transition accepted';
  exception when invalid_parameter_value then null; end;
  job := public.transition_generation_job(job.id,'worker-a','running','succeeded','{"asset":"ready"}');
  if job.state <> 'succeeded' or job.lease_owner is not null or job.completed_at is null then raise exception 'Job completion invalid'; end if;
end$$;

rollback;
\echo 'PASS lifecycle: guarded transitions, version-bound approvals, stale rejection, tenant isolation, and owned job leases'
