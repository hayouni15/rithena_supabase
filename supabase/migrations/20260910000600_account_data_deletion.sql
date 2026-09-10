-- Service-role primitives for complete, user-requested account deletion.

create or replace function public.account_deletion_scope(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare organization_ids uuid[]; stored_objects jsonb;
begin
  if auth.role()<>'service_role' then raise exception 'Account deletion unavailable' using errcode='42501'; end if;

  if exists(
    select 1 from public.organization_members owner_membership
    where owner_membership.user_id=p_user_id and owner_membership.role='owner'
      and exists(select 1 from public.organization_members other where other.organization_id=owner_membership.organization_id and other.user_id<>p_user_id)
  ) then raise exception 'Transfer or remove other workspace members before deleting your account.' using errcode='55000'; end if;

  select coalesce(array_agg(organization_id),'{}'::uuid[]) into organization_ids
  from public.organization_members where user_id=p_user_id and role='owner';

  select coalesce(jsonb_agg(jsonb_build_object('bucket',object.bucket_id,'name',object.name)),'[]'::jsonb)
  into stored_objects from storage.objects object
  where object.bucket_id='creative-media'
    and exists(select 1 from unnest(organization_ids) organization_id where object.name like organization_id::text||'/%');

  return jsonb_build_object('organizationIds',to_jsonb(organization_ids),'storageObjects',stored_objects);
end;
$$;

create or replace function public.delete_account_data(p_user_id uuid,p_organization_ids uuid[])
returns void language plpgsql security definer set search_path='' as $$
begin
  if auth.role()<>'service_role' then raise exception 'Account deletion unavailable' using errcode='42501'; end if;
  if exists(
    select 1 from public.organization_members owner_membership
    where owner_membership.user_id=p_user_id and owner_membership.role='owner'
      and (not owner_membership.organization_id=any(coalesce(p_organization_ids,'{}'::uuid[]))
        or exists(select 1 from public.organization_members other where other.organization_id=owner_membership.organization_id and other.user_id<>p_user_id))
  ) or exists(
    select 1 from unnest(coalesce(p_organization_ids,'{}'::uuid[])) requested_id
    where not exists(select 1 from public.organization_members membership where membership.organization_id=requested_id and membership.user_id=p_user_id and membership.role='owner')
  ) then raise exception 'Account deletion scope changed. Try again.' using errcode='40001'; end if;

  delete from public.organizations where id=any(coalesce(p_organization_ids,'{}'::uuid[]));
  delete from public.profiles where id=p_user_id;
end;
$$;

revoke all on function public.account_deletion_scope(uuid) from public,anon,authenticated;
revoke all on function public.delete_account_data(uuid,uuid[]) from public,anon,authenticated;
grant execute on function public.account_deletion_scope(uuid) to service_role;
grant execute on function public.delete_account_data(uuid,uuid[]) to service_role;
