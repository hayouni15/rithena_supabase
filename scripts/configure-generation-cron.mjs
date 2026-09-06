const required = (name) => {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required to configure the generation cron.`);
  return value;
};

const projectRef = required("SUPABASE_PROJECT_REF");
const accessToken = required("SUPABASE_ACCESS_TOKEN");
const cronSecret = required("CRON_SECRET");
const workerUrl = `https://${projectRef}.supabase.co/functions/v1/generation-worker`;

const literal = (value) => `'${value.replaceAll("'", "''")}'`;
const sql = `
do $configure$
declare existing_id uuid;
begin
  select id into existing_id from vault.secrets where name = 'rithena_worker_url' order by created_at desc limit 1;
  if existing_id is null then
    perform vault.create_secret(${literal(workerUrl)}, 'rithena_worker_url', 'Rithena Supabase Edge worker URL');
  else
    perform vault.update_secret(existing_id, ${literal(workerUrl)}, 'rithena_worker_url', 'Rithena Supabase Edge worker URL');
  end if;

  select id into existing_id from vault.secrets where name = 'rithena_cron_secret' order by created_at desc limit 1;
  if existing_id is null then
    perform vault.create_secret(${literal(cronSecret)}, 'rithena_cron_secret', 'Authorizes Supabase Cron calls to Rithena');
  else
    perform vault.update_secret(existing_id, ${literal(cronSecret)}, 'rithena_cron_secret', 'Authorizes Supabase Cron calls to Rithena');
  end if;
end
$configure$;
`;

const response = await fetch(`https://api.supabase.com/v1/projects/${encodeURIComponent(projectRef)}/database/query`, {
  method: "POST",
  headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
  body: JSON.stringify({ query: sql }),
});
if (!response.ok) throw new Error(`Supabase Vault configuration failed (${response.status}): ${await response.text()}`);
console.log(`Generation cron configured for ${workerUrl}.`);
