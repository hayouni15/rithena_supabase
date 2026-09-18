-- Growth is the temporary default for newly created workspaces.
-- Existing organizations retain their explicitly selected subscription plan.
create or replace function public.handle_new_organization_subscription()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  insert into public.subscriptions(
    organization_id, plan_code, status, trial_started_at,
    trial_ends_at, current_period_started_at, current_period_ends_at
  ) values (
    new.id, 'growth', 'active', null,
    null, now(), now() + interval '1 month'
  ) on conflict(organization_id) do nothing;
  return new;
end;
$$;
