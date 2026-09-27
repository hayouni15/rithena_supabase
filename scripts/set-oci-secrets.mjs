import { spawnSync } from "node:child_process";

const required = (name) => {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required.`);
  return value;
};

const values = {
  OCI_ACCESS_KEY: required("OCI_ACCESS_KEY"),
  OCI_SECRET_KEY: required("OCI_SECRET_KEY"),
  OCI_BUCKET: required("OCI_BUCKET"),
  OCI_NAMESPACE: process.env.OCI_NAMESPACE || "axr2mzsugevy",
  OCI_REGION: process.env.OCI_REGION || "ca-montreal-1",
};

const result = spawnSync("npx", ["supabase", "secrets", "set", "--project-ref", required("PROD_PROJECT_REF"),
  ...Object.entries(values).map(([key, value]) => `${key}=${value}`)], {
  env: { ...process.env, SUPABASE_ACCESS_TOKEN: required("PROD_ACCESS_TOKEN") },
  stdio: "inherit",
});
if (result.error) throw result.error;
if (result.status !== 0) process.exit(result.status || 1);
