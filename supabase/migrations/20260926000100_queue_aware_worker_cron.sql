-- Keep minute-level job latency without invoking idle Edge Functions.
select cron.unschedule('rithena-generation-worker')
where exists (select 1 from cron.job where jobname = 'rithena-generation-worker');

select cron.schedule('rithena-generation-worker', '* * * * *', $worker$
  select net.http_post(
    url := secrets.worker_url,
    headers := jsonb_build_object('Authorization', 'Bearer ' || secrets.cron_secret, 'Content-Type', 'application/json'),
    body := '{}'::jsonb,
    timeout_milliseconds := 120000
  )
  from (
    select max(decrypted_secret) filter (where name = 'rithena_worker_url') as worker_url,
      max(decrypted_secret) filter (where name = 'rithena_cron_secret') as cron_secret
    from vault.decrypted_secrets
  ) secrets
  where secrets.worker_url is not null and secrets.cron_secret is not null
    and exists (
      select 1 from public.generation_jobs j
      where ((j.state in ('queued', 'retrying', 'waiting_external') and j.next_run_at <= now()
        and (j.state = 'waiting_external' or j.attempt < j.max_attempts))
        or (j.state = 'running' and j.lease_expires_at <= now())
        or (j.state in ('queued', 'retrying', 'waiting_external', 'running')
          and coalesce(j.started_at, j.created_at) <= now() - interval '45 minutes'))
        and coalesce(j.input->>'pipeline', '') not like 'product_reference_%'
    );
$worker$);

select cron.unschedule('rithena-product-generation-worker')
where exists (select 1 from cron.job where jobname = 'rithena-product-generation-worker');

select cron.schedule('rithena-product-generation-worker', '* * * * *', $worker$
  select net.http_post(
    url := secrets.worker_url,
    headers := jsonb_build_object('Authorization', 'Bearer ' || secrets.cron_secret, 'Content-Type', 'application/json'),
    body := '{}'::jsonb,
    timeout_milliseconds := 120000
  )
  from (
    select max(decrypted_secret) filter (where name = 'rithena_product_worker_url') as worker_url,
      max(decrypted_secret) filter (where name = 'rithena_cron_secret') as cron_secret
    from vault.decrypted_secrets
  ) secrets
  where secrets.worker_url is not null and secrets.cron_secret is not null
    and exists (
      select 1 from public.generation_jobs j
      where ((j.state in ('queued', 'retrying', 'waiting_external') and j.next_run_at <= now()
          and (j.state = 'waiting_external' or j.attempt < j.max_attempts))
        or (j.state = 'running' and j.lease_expires_at <= now())
        or (j.state in ('queued', 'retrying', 'waiting_external', 'running')
          and coalesce(j.started_at, j.created_at) <= now() - interval '45 minutes'))
        and j.input->>'pipeline' like 'product_reference_%'
    );
$worker$);

select cron.unschedule('rithena-instagram-publisher')
where exists (select 1 from cron.job where jobname = 'rithena-instagram-publisher');

select cron.schedule('rithena-instagram-publisher', '* * * * *', $worker$
  select net.http_post(
    url := secrets.worker_url,
    headers := jsonb_build_object('Authorization', 'Bearer ' || secrets.cron_secret, 'Content-Type', 'application/json'),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000
  )
  from (
    select max(decrypted_secret) filter (where name = 'rithena_publish_worker_url') as worker_url,
      max(decrypted_secret) filter (where name = 'rithena_cron_secret') as cron_secret
    from vault.decrypted_secrets
  ) secrets
  where secrets.worker_url is not null and secrets.cron_secret is not null
    and exists (
      select 1 from public.publish_jobs j
      join public.schedules s on s.id = j.schedule_id
      join public.content_items i on i.id = j.content_item_id
      join public.brands b on b.id = i.brand_id
      where (j.state in ('queued', 'retrying', 'waiting_external')
          and coalesce(j.next_attempt_at, s.scheduled_for) <= now()
          and (j.state = 'waiting_external' or j.attempt < j.max_attempts)
          and s.status = 'scheduled' and not b.autopilot_paused)
        or (j.state = 'running' and j.lease_expires_at <= now())
    );
$worker$);
