create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

select cron.unschedule('rithena-instagram-publisher')
where exists(select 1 from cron.job where jobname='rithena-instagram-publisher');

select cron.schedule('rithena-instagram-publisher','* * * * *',$worker$
  select net.http_post(
    url:=secrets.worker_url,
    headers:=jsonb_build_object('Authorization','Bearer '||secrets.cron_secret,'Content-Type','application/json'),
    body:='{}'::jsonb,timeout_milliseconds:=30000
  ) from (
    select max(decrypted_secret) filter(where name='rithena_publish_worker_url') worker_url,
      max(decrypted_secret) filter(where name='rithena_cron_secret') cron_secret
    from vault.decrypted_secrets
  ) secrets where secrets.worker_url is not null and secrets.cron_secret is not null;
$worker$);
