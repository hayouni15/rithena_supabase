const required = (name) => {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required to verify the email deployment.`);
  return value;
};

const accessToken = required("PROD_ACCESS_TOKEN");
const projectRef = required("PROD_PROJECT_REF");
const query = `
select
  exists(
    select 1 from pg_trigger
    where tgname='wake_email_worker_on_delivery' and not tgisinternal
  ) as event_trigger_ready,
  exists(
    select 1 from cron.job
    where jobname='rithena-email-worker-recovery'
      and schedule='17 4 * * *' and active
  ) as recovery_job_ready,
  not exists(
    select 1 from cron.job where jobname='rithena-email-worker'
  ) as minute_polling_removed,
  exists(
    select 1 from vault.secrets where name='rithena_email_worker_url'
  ) as worker_url_ready,
  exists(
    select 1 from vault.secrets where name='rithena_cron_secret'
  ) as cron_secret_ready;
`;

const response = await fetch(`https://api.supabase.com/v1/projects/${encodeURIComponent(projectRef)}/database/query`, {
  method: "POST",
  headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
  body: JSON.stringify({ query }),
});
if (!response.ok) throw new Error(`Email deployment verification failed (${response.status}): ${await response.text()}`);

const rows = await response.json();
const result = Array.isArray(rows) ? rows[0] : rows;
const checks = ["event_trigger_ready", "recovery_job_ready", "minute_polling_removed", "worker_url_ready", "cron_secret_ready"];
for (const check of checks) console.log(`${check}: ${result?.[check] === true ? "ok" : "FAILED"}`);
if (checks.some((check) => result?.[check] !== true)) process.exit(1);
