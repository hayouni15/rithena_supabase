const required=(name)=>{const value=process.env[name]?.trim();if(!value)throw new Error(`${name} is required to configure the publish cron.`);return value;};
const projectRef=required("SUPABASE_PROJECT_REF"); const accessToken=required("SUPABASE_ACCESS_TOKEN"); const cronSecret=required("CRON_SECRET");
const workerUrl=`https://${projectRef}.supabase.co/functions/v1/publish-worker`;
const literal=(value)=>`'${value.replaceAll("'","''")}'`;
const sql=`do $configure$ declare existing_id uuid; begin
select id into existing_id from vault.secrets where name='rithena_publish_worker_url' order by created_at desc limit 1;
if existing_id is null then perform vault.create_secret(${literal(workerUrl)},'rithena_publish_worker_url','Rithena Instagram publisher URL');
else perform vault.update_secret(existing_id,${literal(workerUrl)},'rithena_publish_worker_url','Rithena Instagram publisher URL'); end if;
select id into existing_id from vault.secrets where name='rithena_cron_secret' order by created_at desc limit 1;
if existing_id is null then perform vault.create_secret(${literal(cronSecret)},'rithena_cron_secret','Authorizes Supabase Cron calls to Rithena');
else perform vault.update_secret(existing_id,${literal(cronSecret)},'rithena_cron_secret','Authorizes Supabase Cron calls to Rithena'); end if;
end $configure$;`;
const response=await fetch(`https://api.supabase.com/v1/projects/${encodeURIComponent(projectRef)}/database/query`,{method:"POST",headers:{Authorization:`Bearer ${accessToken}`,"Content-Type":"application/json"},body:JSON.stringify({query:sql})});
if(!response.ok)throw new Error(`Supabase Vault configuration failed (${response.status}): ${await response.text()}`);
console.log(`Instagram publish cron configured for ${workerUrl}.`);
