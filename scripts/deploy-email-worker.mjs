import { spawnSync } from "node:child_process";

const required = (name, fallback) => {
  const value = (process.env[name] || fallback || "").trim();
  if (!value) throw new Error(`${name} is required to deploy the email worker.`);
  return value;
};

const accessToken = required("PROD_ACCESS_TOKEN");
const projectRef = required("PROD_PROJECT_REF");
const cronSecret = required("CRON_SECRET");
const resendApiKey = required("RESEND_API_KEY");
const fromEmail = required("RESEND_FROM_EMAIL");
const appUrl = required("APP_URL", process.env.NEXT_PUBLIC_SITE_URL);
const parsedAppUrl = new URL(appUrl);
if (parsedAppUrl.protocol !== "https:" || ["localhost", "127.0.0.1", "::1"].includes(parsedAppUrl.hostname)) {
  throw new Error("APP_URL must be the public HTTPS production application URL.");
}
const replyTo = process.env.RESEND_REPLY_TO?.trim();
const workerUrl = `https://${projectRef}.supabase.co/functions/v1/email-worker`;

const run = (args) => {
  const result = spawnSync("npx", args, {
    stdio: "inherit",
    env: { ...process.env, SUPABASE_ACCESS_TOKEN: accessToken },
  });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status || 1);
};

const secrets = [
  `CRON_SECRET=${cronSecret}`,
  `RESEND_API_KEY=${resendApiKey}`,
  `RESEND_FROM_EMAIL=${fromEmail}`,
  `APP_URL=${appUrl}`,
];
if (replyTo) secrets.push(`RESEND_REPLY_TO=${replyTo}`);

run(["supabase", "secrets", "set", "--project-ref", projectRef, ...secrets]);
run(["supabase", "functions", "deploy", "email-worker", "--project-ref", projectRef, "--no-verify-jwt"]);

const literal = (value) => `'${value.replaceAll("'", "''")}'`;
const sql = `
do $configure$
declare existing_id uuid;
begin
  select id into existing_id from vault.secrets where name='rithena_email_worker_url' order by created_at desc limit 1;
  if existing_id is null then
    perform vault.create_secret(${literal(workerUrl)},'rithena_email_worker_url','Rithena email worker URL');
  else
    perform vault.update_secret(existing_id,${literal(workerUrl)},'rithena_email_worker_url','Rithena email worker URL');
  end if;

  select id into existing_id from vault.secrets where name='rithena_cron_secret' order by created_at desc limit 1;
  if existing_id is null then
    perform vault.create_secret(${literal(cronSecret)},'rithena_cron_secret','Authorizes Supabase worker calls');
  else
    perform vault.update_secret(existing_id,${literal(cronSecret)},'rithena_cron_secret','Authorizes Supabase worker calls');
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

console.log(`Email worker deployed and Vault configured for ${workerUrl}.`);
