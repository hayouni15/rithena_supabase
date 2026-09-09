-- T13: approval-bound Instagram scheduling and a durable, duplicate-safe publish queue.

alter table public.schedules add column content_revision integer;
update public.schedules s set content_revision = c.content_revision
from public.content_items c where c.id = s.content_item_id and s.content_revision is null;
alter table public.schedules alter column content_revision set not null;

alter table public.publish_jobs
  add column content_revision integer,
  add column provider_payload jsonb not null default '{}'::jsonb,
  add column lease_owner text,
  add column lease_expires_at timestamptz,
  add constraint publish_jobs_lease_pair check (
    (lease_owner is null and lease_expires_at is null)
    or (lease_owner is not null and btrim(lease_owner) <> '' and lease_expires_at is not null)
  );
update public.publish_jobs j set content_revision = s.content_revision
from public.schedules s where s.id = j.schedule_id and j.content_revision is null;
alter table public.publish_jobs alter column content_revision set not null;

create index publish_jobs_due_instagram_idx
  on public.publish_jobs (next_attempt_at, created_at)
  where state in ('queued','retrying','waiting_external');

create or replace function public.schedule_instagram_content(
  p_content_item_id uuid, p_expected_revision integer, p_scheduled_for timestamptz
) returns public.schedules
language plpgsql security definer set search_path = '' as $$
declare
  item public.content_items; variant public.platform_variants; connection public.social_connections;
  result public.schedules; job public.publish_jobs;
begin
  if p_scheduled_for is null or p_scheduled_for < now() - interval '1 minute'
    or p_scheduled_for > now() + interval '1 year' then
    raise exception 'Choose a valid future publish time' using errcode = '22023';
  end if;
  select * into item from public.content_items where id = p_content_item_id for update;
  if item.id is null or not public.is_organization_member(item.organization_id) then
    raise exception 'Content item unavailable' using errcode = '42501';
  end if;
  if item.content_revision <> p_expected_revision then
    raise exception 'Content item changed' using errcode = '40001';
  end if;
  if item.status not in ('approved','failed') or not ('instagram' = any(item.platform_targets)) then
    raise exception 'Approve the Instagram version before scheduling' using errcode = '22023';
  end if;
  if not exists (
    select 1 from public.approvals a where a.content_item_id=item.id
      and a.content_revision=item.content_revision and a.decision='approved'
  ) then raise exception 'Current content revision is not approved' using errcode = '22023'; end if;

  select * into variant from public.platform_variants
  where content_item_id=item.id and organization_id=item.organization_id
    and platform='instagram' and status='ready' for update;
  if variant.id is null or variant.selected_media_asset_id is null
    or not exists (select 1 from public.media_assets m where m.id=variant.selected_media_asset_id and m.status='ready')
    or not exists (select 1 from public.post_copies p where p.platform_variant_id=variant.id and p.is_selected) then
    raise exception 'The finished Instagram media and copy are not ready' using errcode = '22023';
  end if;
  select * into connection from public.social_connections
  where brand_id=item.brand_id and platform='instagram' and status='connected'
    and token_expires_at > now() and 'instagram_business_content_publish'=any(scopes)
  order by last_validated_at desc nulls last limit 1 for update;
  if connection.id is null then
    raise exception 'Connect or reconnect Instagram before scheduling' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.schedules where content_item_id=item.id and status='scheduled') then
    raise exception 'This content is already scheduled' using errcode = '23505';
  end if;

  if item.status='failed' then
    select * into job from public.publish_jobs where content_item_id=item.id and content_revision=item.content_revision
      and state='failed' order by created_at desc limit 1 for update;
    if job.id is null then raise exception 'This failed post cannot be rescheduled' using errcode='22023'; end if;
    if job.error_code='publish_outcome_unknown' then
      raise exception 'Check Instagram before retrying because the previous publish result is unknown' using errcode='22023';
    end if;
    perform set_config('rithena.lifecycle_transition','allowed',true);
    update public.content_items set status='scheduled',failure_code=null,failure_message=null where id=item.id;
    update public.schedules set status='scheduled',scheduled_for=p_scheduled_for,social_connection_id=connection.id
      where id=job.schedule_id returning * into result;
    update public.publish_jobs set state='queued',social_connection_id=connection.id,attempt=0,next_attempt_at=p_scheduled_for,
      completed_at=null,error_code=null,error_message=null,lease_owner=null,lease_expires_at=null where id=job.id;
    return result;
  end if;

  insert into public.schedules(organization_id,content_item_id,platform_variant_id,social_connection_id,
    content_revision,scheduled_for,timezone,status,created_by)
  values(item.organization_id,item.id,variant.id,connection.id,item.content_revision,p_scheduled_for,
    coalesce((select timezone from public.brands where id=item.brand_id),'UTC'),'scheduled',auth.uid())
  returning * into result;
  insert into public.publish_jobs(organization_id,schedule_id,content_item_id,platform_variant_id,
    social_connection_id,content_revision,state,idempotency_key,next_attempt_at,max_attempts)
  values(item.organization_id,result.id,item.id,variant.id,connection.id,item.content_revision,'queued',
    'instagram:'||item.id::text||':revision:'||item.content_revision::text,p_scheduled_for,5)
  returning * into job;
  perform set_config('rithena.lifecycle_transition','allowed',true);
  update public.content_items set status='scheduled',failure_code=null,failure_message=null where id=item.id;
  return result;
end;
$$;

create or replace function public.claim_next_instagram_publish_job(
  p_worker_id text, p_lease_seconds integer default 120
) returns public.publish_jobs
language plpgsql security definer set search_path = '' as $$
declare job public.publish_jobs;
begin
  if coalesce(length(btrim(p_worker_id)),0)=0 or p_lease_seconds not between 15 and 600 then
    raise exception 'Invalid worker lease' using errcode='22023';
  end if;
  update public.publish_jobs set state='retrying',lease_owner=null,lease_expires_at=null,
    next_attempt_at=now(),error_code='lease_expired',error_message='The publisher stopped before completing this attempt.'
  where state='running' and lease_expires_at<=now() and attempt<max_attempts;
  update public.publish_jobs set state='failed',lease_owner=null,lease_expires_at=null,completed_at=now(),
    error_code='attempts_exhausted',error_message='Publishing attempts were exhausted.'
  where state='running' and lease_expires_at<=now() and attempt>=max_attempts;
  update public.schedules s set status='failed' from public.publish_jobs j
    where j.schedule_id=s.id and j.state='failed' and j.error_code='attempts_exhausted' and s.status='scheduled';
  perform set_config('rithena.lifecycle_transition','allowed',true);
  update public.content_items c set status='failed',failure_code='attempts_exhausted',
    failure_message='Publishing attempts were exhausted.' from public.publish_jobs j
    where j.content_item_id=c.id and j.content_revision=c.content_revision
      and j.state='failed' and j.error_code='attempts_exhausted' and c.status='publishing';
  select j.* into job from public.publish_jobs j join public.schedules s on s.id=j.schedule_id
  where j.state in ('queued','retrying','waiting_external') and coalesce(j.next_attempt_at,s.scheduled_for)<=now()
    and (j.state='waiting_external' or j.attempt<j.max_attempts) and s.status='scheduled'
  order by coalesce(j.next_attempt_at,s.scheduled_for),j.created_at for update of j skip locked limit 1;
  if job.id is null then return null; end if;
  update public.publish_jobs set state='running',lease_owner=p_worker_id,
    lease_expires_at=now()+make_interval(secs=>p_lease_seconds),
    attempt=case when job.state='waiting_external' then attempt else attempt+1 end,
    started_at=coalesce(started_at,now()),error_code=null,error_message=null
  where id=job.id returning * into job;
  perform set_config('rithena.lifecycle_transition','allowed',true);
  update public.content_items set status='publishing'
  where id=job.content_item_id and status='scheduled' and content_revision=job.content_revision;
  return job;
end;
$$;

create or replace function public.instagram_publish_credential(p_job_id uuid,p_worker_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare job public.publish_jobs; c public.social_connections; secret private.instagram_credentials;
begin
  select * into job from public.publish_jobs where id=p_job_id for update;
  if job.id is null or job.state<>'running' or job.lease_owner is distinct from p_worker_id
    or job.lease_expires_at<=now() then raise exception 'Publish job lease unavailable' using errcode='42501'; end if;
  select * into c from public.social_connections
    where id=job.social_connection_id and platform='instagram';
  select * into secret from private.instagram_credentials where connection_id=c.id;
  if c.id is null or secret.connection_id is null or c.status<>'connected' or c.token_expires_at<=now() then
    raise exception 'Instagram must be reconnected' using errcode='P0001';
  end if;
  return jsonb_build_object('ciphertext',secret.ciphertext,'organizationId',job.organization_id,
    'brandId',c.brand_id,'connectionId',c.id,'accountId',c.provider_account_id);
end;
$$;

create or replace function public.checkpoint_instagram_publish_job(
  p_job_id uuid,p_worker_id text,p_state public.job_state,p_provider_job_id text default null,
  p_provider_payload jsonb default '{}'::jsonb,p_retry_after_seconds integer default null,
  p_error_code text default null,p_error_message text default null,p_remote_post_id text default null,
  p_remote_post_url text default null
) returns public.publish_jobs language plpgsql security definer set search_path='' as $$
declare job public.publish_jobs; next_attempt timestamptz; owner uuid;
begin
  select * into job from public.publish_jobs where id=p_job_id for update;
  if job.id is null or job.state<>'running' or job.lease_owner is distinct from p_worker_id
    or job.lease_expires_at<=now() then raise exception 'Publish job lease unavailable' using errcode='42501'; end if;
  if p_state not in ('waiting_external','retrying','succeeded','failed') then raise exception 'Invalid checkpoint' using errcode='22023'; end if;
  if p_state='succeeded' and coalesce(btrim(p_remote_post_id),'')='' then raise exception 'Remote post ID required' using errcode='22023'; end if;
  next_attempt := case when p_retry_after_seconds is null then null else now()+make_interval(secs=>p_retry_after_seconds) end;
  insert into public.publish_attempts(organization_id,publish_job_id,attempt_number,state,request_summary,
    response_summary,error_code,error_message,finished_at)
  values(job.organization_id,job.id,greatest(job.attempt,1),p_state,
    jsonb_build_object('platform','instagram','contentRevision',job.content_revision),coalesce(p_provider_payload,'{}'),
    p_error_code,p_error_message,now())
  on conflict(publish_job_id,attempt_number) do update set state=excluded.state,response_summary=excluded.response_summary,
    error_code=excluded.error_code,error_message=excluded.error_message,finished_at=excluded.finished_at;
  update public.publish_jobs set state=p_state,provider_job_id=coalesce(p_provider_job_id,provider_job_id),
    provider_payload=provider_payload||coalesce(p_provider_payload,'{}'),next_attempt_at=next_attempt,
    error_code=p_error_code,error_message=p_error_message,completed_at=case when p_state in ('succeeded','failed') then now() end,
    lease_owner=null,lease_expires_at=null where id=job.id returning * into job;
  if p_state='succeeded' then
    insert into public.published_posts(organization_id,publish_job_id,content_item_id,platform_variant_id,
      social_connection_id,remote_post_id,remote_post_url,published_at,provider_payload)
    values(job.organization_id,job.id,job.content_item_id,job.platform_variant_id,job.social_connection_id,
      p_remote_post_id,p_remote_post_url,now(),coalesce(p_provider_payload,'{}')) on conflict(publish_job_id) do nothing;
    update public.schedules set status='completed' where id=job.schedule_id;
    perform set_config('rithena.lifecycle_transition','allowed',true);
    update public.content_items set status='published',failure_code=null,failure_message=null
      where id=job.content_item_id and status='publishing' and content_revision=job.content_revision;
    update public.social_connections set last_successful_publish_at=now(),last_validated_at=now(),last_error_code=null,last_error_message=null
      where id=job.social_connection_id;
  elsif p_state='failed' then
    update public.schedules set status='failed' where id=job.schedule_id;
    perform set_config('rithena.lifecycle_transition','allowed',true);
    update public.content_items set status='failed',failure_code=p_error_code,failure_message=p_error_message
      where id=job.content_item_id and status in ('scheduled','publishing') and content_revision=job.content_revision;
    if p_error_code in ('instagram_expired','instagram_revoked','instagram_permissions','credential_invalid') then
      update public.social_connections set status=case when p_error_code='instagram_expired' then 'expired'::public.connection_status else 'revoked'::public.connection_status end,
        last_error_code=p_error_code,last_error_message=p_error_message where id=job.social_connection_id;
    end if;
    for owner in select user_id from public.organization_members where organization_id=job.organization_id and role='owner' loop
      insert into public.notifications(organization_id,user_id,content_item_id,type,title,message,action_url)
      values(job.organization_id,owner,job.content_item_id,'publishing_failed','Instagram publishing needs attention',
        coalesce(p_error_message,'The Instagram post could not be published.'),'/content/'||job.content_item_id::text);
    end loop;
  end if;
  return job;
end;
$$;

revoke all on function public.schedule_instagram_content(uuid,integer,timestamptz) from public,anon;
grant execute on function public.schedule_instagram_content(uuid,integer,timestamptz) to authenticated;
revoke all on function public.claim_next_instagram_publish_job(text,integer) from public,anon,authenticated;
revoke all on function public.instagram_publish_credential(uuid,text) from public,anon,authenticated;
revoke all on function public.checkpoint_instagram_publish_job(uuid,text,public.job_state,text,jsonb,integer,text,text,text,text) from public,anon,authenticated;
grant execute on function public.claim_next_instagram_publish_job(text,integer) to service_role;
grant execute on function public.instagram_publish_credential(uuid,text) to service_role;
grant execute on function public.checkpoint_instagram_publish_job(uuid,text,public.job_state,text,jsonb,integer,text,text,text,text) to service_role;
