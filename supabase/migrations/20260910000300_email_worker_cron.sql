create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

-- New outbox rows wake the worker immediately. pg_net dispatches the request
-- after the surrounding transaction commits, so email delivery cannot block or
-- roll back the product action that created the event.
create or replace function public.wake_email_worker()
returns trigger language plpgsql security definer set search_path='' as $$
declare worker_url text; cron_secret text;
begin
  select max(decrypted_secret) filter(where name='rithena_email_worker_url'),
    max(decrypted_secret) filter(where name='rithena_cron_secret')
  into worker_url,cron_secret
  from vault.decrypted_secrets;

  if worker_url is not null and cron_secret is not null then
    perform net.http_post(
      url:=worker_url,
      headers:=jsonb_build_object(
        'Authorization','Bearer '||cron_secret,
        'Content-Type','application/json'
      ),
      body:=jsonb_build_object('deliveryId',new.id),
      timeout_milliseconds:=30000
    );
  end if;
  return new;
end;
$$;

drop trigger if exists wake_email_worker_on_delivery on public.email_deliveries;
create trigger wake_email_worker_on_delivery
after insert on public.email_deliveries
for each row execute function public.wake_email_worker();

revoke all on function public.wake_email_worker() from public,anon,authenticated;

select cron.unschedule('rithena-email-worker')
where exists(select 1 from cron.job where jobname='rithena-email-worker');
select cron.unschedule('rithena-email-worker-recovery')
where exists(select 1 from cron.job where jobname='rithena-email-worker-recovery');

-- Recovery only: normal delivery is event-driven above. This catches an HTTP
-- wake-up missed during an outage and deliveries waiting for a later retry.
select cron.schedule('rithena-email-worker-recovery','17 4 * * *',$worker$
  select net.http_post(
    url:=secrets.worker_url,
    headers:=jsonb_build_object('Authorization','Bearer '||secrets.cron_secret,'Content-Type','application/json'),
    body:='{}'::jsonb,timeout_milliseconds:=30000
  ) from (
    select max(decrypted_secret) filter(where name='rithena_email_worker_url') worker_url,
      max(decrypted_secret) filter(where name='rithena_cron_secret') cron_secret
    from vault.decrypted_secrets
  ) secrets where secrets.worker_url is not null and secrets.cron_secret is not null;
$worker$);
