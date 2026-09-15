-- TikTok direct video publishing through the durable social publish queue.

create or replace function public.schedule_tiktok_content(p_content_item_id uuid,p_expected_revision integer,p_scheduled_for timestamptz,p_settings jsonb default '{}')
returns public.schedules language plpgsql security definer set search_path='' as $$
declare item public.content_items; variant public.platform_variants; connection public.social_connections; result public.schedules; job public.publish_jobs; settings jsonb;
begin
 if p_scheduled_for is null or p_scheduled_for<now()-interval '1 minute' or p_scheduled_for>now()+interval '1 year' then raise exception 'Choose a valid future publish time' using errcode='22023'; end if;
 if p_settings->>'privacyLevel' not in ('PUBLIC_TO_EVERYONE','MUTUAL_FOLLOW_FRIENDS','FOLLOWER_OF_CREATOR','SELF_ONLY') then raise exception 'Choose an available TikTok privacy setting' using errcode='22023'; end if;
 settings:=jsonb_build_object('privacyLevel',p_settings->>'privacyLevel','disableComment',coalesce((p_settings->>'disableComment')::boolean,false),'disableDuet',coalesce((p_settings->>'disableDuet')::boolean,false),'disableStitch',coalesce((p_settings->>'disableStitch')::boolean,false));
 select * into item from public.content_items where id=p_content_item_id for update;
 if item.id is null or not public.is_organization_member(item.organization_id) then raise exception 'Content item unavailable' using errcode='42501'; end if;
 if item.content_revision<>p_expected_revision then raise exception 'Content item changed' using errcode='40001'; end if;
 if item.status not in ('approved','failed') or not ('tiktok'=any(item.platform_targets)) then raise exception 'Approve the TikTok version before scheduling' using errcode='22023'; end if;
 if item.format<>'short_video' then raise exception 'TikTok publishing requires a finished video creative' using errcode='22023'; end if;
 if not exists(select 1 from public.approvals a where a.content_item_id=item.id and a.content_revision=item.content_revision and a.decision='approved') then raise exception 'Current content revision is not approved' using errcode='22023'; end if;
 select * into variant from public.platform_variants where content_item_id=item.id and organization_id=item.organization_id and platform='tiktok' and status='ready' for update;
 if variant.id is null or variant.selected_media_asset_id is null or not exists(select 1 from public.media_assets m where m.id=variant.selected_media_asset_id and m.status='ready' and m.mime_type in ('video/mp4','video/quicktime','video/webm')) or not exists(select 1 from public.post_copies p where p.platform_variant_id=variant.id and p.is_selected) then raise exception 'The finished TikTok video and copy are not ready' using errcode='22023'; end if;
 select * into connection from public.social_connections where brand_id=item.brand_id and platform='tiktok' and status='connected' and 'video.publish'=any(scopes) order by last_validated_at desc nulls last limit 1 for update;
 if connection.id is null then raise exception 'Connect or reconnect TikTok before scheduling' using errcode='P0001'; end if;
 if exists(select 1 from public.schedules where content_item_id=item.id and status='scheduled') then raise exception 'This content is already scheduled' using errcode='23505'; end if;
 if item.status='failed' then
  select j.* into job from public.publish_jobs j join public.platform_variants v on v.id=j.platform_variant_id where j.content_item_id=item.id and j.content_revision=item.content_revision and j.state='failed' and v.platform='tiktok' order by j.created_at desc limit 1 for update of j;
  if job.id is null then raise exception 'This failed post cannot be rescheduled' using errcode='22023'; end if;
  if job.error_code='publish_outcome_unknown' then raise exception 'Check TikTok first because the previous publish result is unknown' using errcode='22023'; end if;
  perform set_config('rithena.lifecycle_transition','allowed',true); update public.content_items set status='scheduled',failure_code=null,failure_message=null where id=item.id;
  update public.schedules set status='scheduled',scheduled_for=p_scheduled_for,social_connection_id=connection.id where id=job.schedule_id returning * into result;
  update public.publish_jobs set state='queued',social_connection_id=connection.id,attempt=0,next_attempt_at=p_scheduled_for,completed_at=null,error_code=null,error_message=null,provider_job_id=null,provider_payload=jsonb_build_object('settings',settings),lease_owner=null,lease_expires_at=null where id=job.id; return result;
 end if;
 insert into public.schedules(organization_id,content_item_id,platform_variant_id,social_connection_id,content_revision,scheduled_for,timezone,status,created_by) values(item.organization_id,item.id,variant.id,connection.id,item.content_revision,p_scheduled_for,coalesce((select timezone from public.brands where id=item.brand_id),'UTC'),'scheduled',auth.uid()) returning * into result;
 insert into public.publish_jobs(organization_id,schedule_id,content_item_id,platform_variant_id,social_connection_id,content_revision,state,idempotency_key,next_attempt_at,max_attempts,provider_payload) values(item.organization_id,result.id,item.id,variant.id,connection.id,item.content_revision,'queued','tiktok:'||item.id::text||':revision:'||item.content_revision::text,p_scheduled_for,5,jsonb_build_object('settings',settings));
 perform set_config('rithena.lifecycle_transition','allowed',true); update public.content_items set status='scheduled',failure_code=null,failure_message=null where id=item.id; return result;
end $$;

create or replace function public.social_publish_credential(p_job_id uuid,p_worker_id text) returns jsonb language plpgsql security definer set search_path='' as $$
declare job public.publish_jobs; c public.social_connections; cipher text;
begin
 select * into job from public.publish_jobs where id=p_job_id for update;
 if job.id is null or job.state<>'running' or job.lease_owner is distinct from p_worker_id or job.lease_expires_at<=now() then raise exception 'Publish job lease unavailable' using errcode='42501'; end if;
 select * into c from public.social_connections where id=job.social_connection_id;
 if c.platform='instagram' then select ciphertext into cipher from private.instagram_credentials where connection_id=c.id;
 elsif c.platform='facebook' then select ciphertext into cipher from private.facebook_credentials where connection_id=c.id;
 elsif c.platform='linkedin' then select ciphertext into cipher from private.linkedin_credentials where connection_id=c.id;
 elsif c.platform='youtube' then select ciphertext into cipher from private.youtube_credentials where connection_id=c.id;
 elsif c.platform='tiktok' then select ciphertext into cipher from private.tiktok_credentials where connection_id=c.id;
 else raise exception 'Unsupported publishing platform' using errcode='22023'; end if;
 if c.id is null or cipher is null or c.status<>'connected' or (c.platform not in ('youtube','tiktok') and c.token_expires_at<=now()) then raise exception 'Social account must be reconnected' using errcode='P0001'; end if;
 return jsonb_build_object('ciphertext',cipher,'organizationId',job.organization_id,'brandId',c.brand_id,'connectionId',c.id,'accountId',c.provider_account_id,'platform',c.platform);
end $$;

create or replace function public.cancel_tiktok_schedule(p_content_item_id uuid,p_expected_revision integer) returns public.schedules language plpgsql security definer set search_path='' as $$
declare job public.publish_jobs; schedule public.schedules; item public.content_items;
begin
 select j.* into job from public.publish_jobs j join public.platform_variants v on v.id=j.platform_variant_id where j.content_item_id=p_content_item_id and v.platform='tiktok' and public.is_organization_member(j.organization_id) order by j.created_at desc limit 1 for update of j;
 if job.id is null then raise exception 'Schedule unavailable' using errcode='42501'; end if;
 select * into schedule from public.schedules where id=job.schedule_id for update; select * into item from public.content_items where id=job.content_item_id for update;
 if item.content_revision<>p_expected_revision then raise exception 'Content item changed' using errcode='40001'; end if;
 if item.status<>'scheduled' or schedule.status<>'scheduled' or job.state not in ('queued','retrying','waiting_external') or job.provider_job_id is not null then raise exception 'Publishing has already started' using errcode='55000'; end if;
 update public.publish_jobs set state='cancelled',completed_at=now(),next_attempt_at=null,idempotency_key=idempotency_key||':cancelled:'||id::text,error_code=null,error_message=null,lease_owner=null,lease_expires_at=null where id=job.id;
 update public.schedules set status='cancelled' where id=schedule.id returning * into schedule; perform set_config('rithena.lifecycle_transition','allowed',true); update public.content_items set status='approved',failure_code=null,failure_message=null where id=item.id; return schedule;
end $$;

revoke all on function public.schedule_tiktok_content(uuid,integer,timestamptz,jsonb),public.cancel_tiktok_schedule(uuid,integer) from public,anon;
grant execute on function public.schedule_tiktok_content(uuid,integer,timestamptz,jsonb),public.cancel_tiktok_schedule(uuid,integer) to authenticated;
