-- Strategy failures are refunded by the trusted application service client.

create or replace function public.release_regeneration_credits(p_organization_id uuid,p_idempotency_key text)
returns void language plpgsql security definer set search_path='' as $$
begin
  if (select auth.role()) <> 'service_role' then raise exception 'Regeneration refunds require the service role' using errcode='42501'; end if;
  delete from public.usage_events where organization_id=p_organization_id and event_type='regeneration_credit' and idempotency_key=p_idempotency_key;
end;
$$;
revoke all on function public.release_regeneration_credits(uuid,text) from public,anon,authenticated;
grant execute on function public.release_regeneration_credits(uuid,text) to service_role;
