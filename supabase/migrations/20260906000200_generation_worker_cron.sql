-- Supabase Cron wakes the durable generation worker. Secrets stay in Vault.

create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

select cron.schedule(
  'rithena-generation-worker',
  '* * * * *',
  $worker$
    select net.http_get(
      url := secrets.app_url || '/api/generation/worker',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || secrets.cron_secret,
        'User-Agent', 'rithena-supabase-cron'
      ),
      timeout_milliseconds := 50000
    )
    from (
      select
        max(decrypted_secret) filter (where name = 'rithena_app_url') as app_url,
        max(decrypted_secret) filter (where name = 'rithena_cron_secret') as cron_secret
      from vault.decrypted_secrets
    ) secrets
    where secrets.app_url is not null and secrets.cron_secret is not null;
  $worker$
);

