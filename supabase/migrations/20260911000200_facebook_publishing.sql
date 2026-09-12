-- Facebook Page scheduling through the existing durable publish queue.

create or replace function public.schedule_facebook_content(p_content_item_id uuid,p_expected_revision integer,p_scheduled_for timestamptz)
returns public.schedules language plpgsql security definer set search_path='' as $$
declare item public.content_items; variant public.platform_variants; connection public.social_connections; result public.schedules; job public.publish_jobs;
begin
 if p_scheduled_for is null or p_scheduled_for<now()-interval '1 minute' or p_scheduled_for>now()+interval '1 year' then raise exception 'Choose a valid future publish time' using errcode='22023'; end if;
 select * into item from public.content_items where id=p_content_item_id for update;
 if item.id is null or not public.is_organization_member(item.organization_id) then raise exception 'Content item unavailable' using errcode='42501'; end if;
 if item.content_revision<>p_expected_revision then raise exception 'Content item changed' using errcode='40001'; end if;
 if item.status not in ('approved','failed') or not ('facebook'=any(item.platform_targets)) then raise exception 'Approve the Facebook version before scheduling' using errcode='22023'; end if;
 if not exists(select 1 from public.approvals a where a.content_item_id=item.id and a.content_revision=item.content_revision and a.decision='approved') then raise exception 'Current content revision is not approved' using errcode='22023'; end if;
 select * into variant from public.platform_variants where content_item_id=item.id and organization_id=item.organization_id and platform='facebook' and status='ready' for update;
 if variant.id is null or variant.selected_media_asset_id is null or not exists(select 1 from public.media_assets m where m.id=variant.selected_media_asset_id and m.status='ready') or not exists(select 1 from public.post_copies p where p.platform_variant_id=variant.id and p.is_selected) then raise exception 'The finished Facebook media and copy are not ready' using errcode='22023'; end if;
 select * into connection from public.social_connections where brand_id=item.brand_id and platform='facebook' and status='connected' and token_expires_at>now() and 'pages_manage_posts'=any(scopes) order by last_validated_at desc nulls last limit 1 for update;
 if connection.id is null then raise exception 'Connect or reconnect Facebook before scheduling' using errcode='P0001'; end if;
 if exists(select 1 from public.schedules where content_item_id=item.id and status='scheduled') then raise exception 'This content is already scheduled' using errcode='23505'; end if;
 if item.status='failed' then
  select j.* into job from public.publish_jobs j join public.platform_variants v on v.id=j.platform_variant_id where j.content_item_id=item.id and j.content_revision=item.content_revision and j.state='failed' and v.platform='facebook' order by j.created_at desc limit 1 for update of j;
  if job.id is null then raise exception 'This failed post cannot be rescheduled' using errcode='22023'; end if;
  if job.error_code='publish_outcome_unknown' then raise exception 'Check Facebook first because the previous publish result is unknown' using errcode='22023'; end if;
  perform set_config('rithena.lifecycle_transition','allowed',true);
  update public.content_items set status='scheduled',failure_code=null,failure_message=null where id=item.id;
  update public.schedules set status='scheduled',scheduled_for=p_scheduled_for,social_connection_id=connection.id where id=job.schedule_id returning * into result;
  update public.publish_jobs set state='queued',social_connection_id=connection.id,attempt=0,next_attempt_at=p_scheduled_for,completed_at=null,error_code=null,error_message=null,provider_job_id=null,provider_payload='{}',lease_owner=null,lease_expires_at=null where id=job.id;
  return result;
 end if;
 insert into public.schedules(organization_id,content_item_id,platform_variant_id,social_connection_id,content_revision,scheduled_for,timezone,status,created_by)
 values(item.organization_id,item.id,variant.id,connection.id,item.content_revision,p_scheduled_for,coalesce((select timezone from public.brands where id=item.brand_id),'UTC'),'scheduled',auth.uid()) returning * into result;
 insert into public.publish_jobs(organization_id,schedule_id,content_item_id,platform_variant_id,social_connection_id,content_revision,state,idempotency_key,next_attempt_at,max_attempts)
 values(item.organization_id,result.id,item.id,variant.id,connection.id,item.content_revision,'queued','facebook:'||item.id::text||':revision:'||item.content_revision::text,p_scheduled_for,5);
 perform set_config('rithena.lifecycle_transition','allowed',true);
 update public.content_items set status='scheduled',failure_code=null,failure_message=null where id=item.id;
 return result;
end $$;

create or replace function public.social_publish_credential(p_job_id uuid,p_worker_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare job public.publish_jobs; c public.social_connections; cipher text;
begin
 select * into job from public.publish_jobs where id=p_job_id for update;
 if job.id is null or job.state<>'running' or job.lease_owner is distinct from p_worker_id or job.lease_expires_at<=now() then raise exception 'Publish job lease unavailable' using errcode='42501'; end if;
 select * into c from public.social_connections where id=job.social_connection_id;
 if c.platform='instagram' then select ciphertext into cipher from private.instagram_credentials where connection_id=c.id;
 elsif c.platform='facebook' then select ciphertext into cipher from private.facebook_credentials where connection_id=c.id;
 else raise exception 'Unsupported publishing platform' using errcode='22023'; end if;
 if c.id is null or cipher is null or c.status<>'connected' or c.token_expires_at<=now() then raise exception 'Social account must be reconnected' using errcode='P0001'; end if;
 return jsonb_build_object('ciphertext',cipher,'organizationId',job.organization_id,'brandId',c.brand_id,'connectionId',c.id,'accountId',c.provider_account_id,'platform',c.platform);
end $$;

create or replace function public.checkpoint_social_publish_job(p_job_id uuid,p_worker_id text,p_state public.job_state,p_provider_job_id text default null,p_provider_payload jsonb default '{}',p_retry_after_seconds integer default null,p_error_code text default null,p_error_message text default null,p_remote_post_id text default null,p_remote_post_url text default null)
returns public.publish_jobs language plpgsql security definer set search_path='' as $$
declare job public.publish_jobs; next_attempt timestamptz; owner uuid; platform public.social_platform;
begin
 select j.* into job from public.publish_jobs j where j.id=p_job_id for update;
 select v.platform into platform from public.platform_variants v where v.id=job.platform_variant_id;
 if job.id is null or job.state<>'running' or job.lease_owner is distinct from p_worker_id or job.lease_expires_at<=now() then raise exception 'Publish job lease unavailable' using errcode='42501'; end if;
 if p_state not in ('waiting_external','retrying','succeeded','failed') then raise exception 'Invalid checkpoint' using errcode='22023'; end if;
 if p_state='succeeded' and coalesce(btrim(p_remote_post_id),'')='' then raise exception 'Remote post ID required' using errcode='22023'; end if;
 next_attempt:=case when p_retry_after_seconds is null then null else now()+make_interval(secs=>p_retry_after_seconds) end;
 insert into public.publish_attempts(organization_id,publish_job_id,attempt_number,state,request_summary,response_summary,error_code,error_message,finished_at)
 values(job.organization_id,job.id,greatest(job.attempt,1),p_state,jsonb_build_object('platform',platform,'contentRevision',job.content_revision),coalesce(p_provider_payload,'{}'),p_error_code,p_error_message,now())
 on conflict(publish_job_id,attempt_number) do update set state=excluded.state,response_summary=excluded.response_summary,error_code=excluded.error_code,error_message=excluded.error_message,finished_at=excluded.finished_at;
 update public.publish_jobs set state=p_state,provider_job_id=coalesce(p_provider_job_id,provider_job_id),provider_payload=provider_payload||coalesce(p_provider_payload,'{}'),next_attempt_at=next_attempt,error_code=p_error_code,error_message=p_error_message,completed_at=case when p_state in ('succeeded','failed') then now() end,lease_owner=null,lease_expires_at=null where id=job.id returning * into job;
 if p_state='succeeded' then
  insert into public.published_posts(organization_id,publish_job_id,content_item_id,platform_variant_id,social_connection_id,remote_post_id,remote_post_url,published_at,provider_payload) values(job.organization_id,job.id,job.content_item_id,job.platform_variant_id,job.social_connection_id,p_remote_post_id,p_remote_post_url,now(),coalesce(p_provider_payload,'{}')) on conflict(publish_job_id) do nothing;
  update public.schedules set status='completed' where id=job.schedule_id; perform set_config('rithena.lifecycle_transition','allowed',true);
  update public.content_items set status='published',failure_code=null,failure_message=null where id=job.content_item_id and status='publishing' and content_revision=job.content_revision;
  update public.social_connections set last_successful_publish_at=now(),last_validated_at=now(),last_error_code=null,last_error_message=null where id=job.social_connection_id;
 elsif p_state='failed' then
  update public.schedules set status='failed' where id=job.schedule_id; perform set_config('rithena.lifecycle_transition','allowed',true);
  update public.content_items set status='failed',failure_code=p_error_code,failure_message=p_error_message where id=job.content_item_id and status in ('scheduled','publishing') and content_revision=job.content_revision;
  if p_error_code in ('instagram_expired','instagram_revoked','instagram_permissions','facebook_expired','facebook_revoked','facebook_permissions','credential_invalid') then update public.social_connections set status=case when p_error_code in ('instagram_expired','facebook_expired') then 'expired'::public.connection_status else 'revoked'::public.connection_status end,last_error_code=p_error_code,last_error_message=p_error_message where id=job.social_connection_id; end if;
  for owner in select user_id from public.organization_members where organization_id=job.organization_id and role='owner' loop insert into public.notifications(organization_id,user_id,content_item_id,type,title,message,action_url) values(job.organization_id,owner,job.content_item_id,'publishing_failed',initcap(platform::text)||' publishing needs attention',coalesce(p_error_message,'The social post could not be published.'),'/content/'||job.content_item_id::text); end loop;
 end if;
 return job;
end $$;

create or replace function public.cancel_facebook_schedule(p_content_item_id uuid,p_expected_revision integer) returns public.schedules language plpgsql security definer set search_path='' as $$
declare job public.publish_jobs; schedule public.schedules; item public.content_items;
begin
 select j.* into job from public.publish_jobs j join public.platform_variants v on v.id=j.platform_variant_id where j.content_item_id=p_content_item_id and v.platform='facebook' and public.is_organization_member(j.organization_id) order by j.created_at desc limit 1 for update of j;
 if job.id is null then raise exception 'Schedule unavailable' using errcode='42501'; end if;
 select * into schedule from public.schedules where id=job.schedule_id for update; select * into item from public.content_items where id=job.content_item_id for update;
 if item.content_revision<>p_expected_revision then raise exception 'Content item changed' using errcode='40001'; end if;
 if item.status<>'scheduled' or schedule.status<>'scheduled' or job.state not in ('queued','retrying','waiting_external') or job.provider_job_id is not null then raise exception 'Publishing has already started' using errcode='55000'; end if;
 update public.publish_jobs set state='cancelled',completed_at=now(),next_attempt_at=null,idempotency_key=idempotency_key||':cancelled:'||id::text,error_code=null,error_message=null,lease_owner=null,lease_expires_at=null where id=job.id;
 update public.schedules set status='cancelled' where id=schedule.id returning * into schedule; perform set_config('rithena.lifecycle_transition','allowed',true); update public.content_items set status='approved',failure_code=null,failure_message=null where id=item.id; return schedule;
end $$;

revoke all on function public.schedule_facebook_content(uuid,integer,timestamptz),public.social_publish_credential(uuid,text),public.checkpoint_social_publish_job(uuid,text,public.job_state,text,jsonb,integer,text,text,text,text),public.cancel_facebook_schedule(uuid,integer) from public,anon;
grant execute on function public.schedule_facebook_content(uuid,integer,timestamptz),public.cancel_facebook_schedule(uuid,integer) to authenticated;
grant execute on function public.social_publish_credential(uuid,text),public.checkpoint_social_publish_job(uuid,text,public.job_state,text,jsonb,integer,text,text,text,text) to service_role;

create or replace function public.enqueue_published_email() returns trigger language plpgsql security definer set search_path='' as $$
declare item public.content_items; platform public.social_platform;
begin
 select * into item from public.content_items where id=new.content_item_id;
 select v.platform into platform from public.platform_variants v where v.id=new.platform_variant_id;
 perform public.enqueue_organization_email(new.organization_id,new.content_item_id,'content_published','published:'||new.id::text,
  jsonb_build_object('title',item.working_title,'platform',initcap(platform::text),'publishedAt',new.published_at,'remotePostUrl',new.remote_post_url,'actionUrl','/content/'||new.content_item_id::text));
 return new;
end $$;
