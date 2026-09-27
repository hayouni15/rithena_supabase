import { createHash } from "node:crypto";
import { AwsClient } from "aws4fetch";
import { createClient } from "@supabase/supabase-js";

const apply = process.argv.includes("--apply");
const cleanup = process.argv.includes("--cleanup");
const destroyCreatives = process.argv.includes("--destroy-creatives");
if ([apply, cleanup, destroyCreatives].filter(Boolean).length > 1) throw new Error("Choose one storage action at a time.");
if (cleanup && !process.argv.includes("--confirm-production-cutover")) {
  throw new Error("Deleting Supabase originals requires --confirm-production-cutover.");
}
if (destroyCreatives && !process.argv.includes("--confirm-destroy-old-creatives")) {
  throw new Error("Destroying old creatives requires --confirm-destroy-old-creatives.");
}

const required = (name) => {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required.`);
  return value;
};

const staging = process.argv.includes("--staging");
const projectRef = required(staging ? "STAGING_PROJECT_REF" : "PROD_PROJECT_REF");
const secretKey = required(staging ? "SUPABASE_SERVICE_ROLE_KEY" : "PROD_SERVICE_ROLE_KEY");
const supabase = createClient(`https://${projectRef}.supabase.co`, secretKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const schema = await supabase.from("media_assets").select("id").limit(1);
if (schema.error) throw new Error(`The ${staging ? "staging" : "production"} service key cannot read the media schema: ${schema.error.message}`);
const namespace = process.env.OCI_NAMESPACE || "axr2mzsugevy";
const region = process.env.OCI_REGION || "ca-montreal-1";
const bucket = apply || cleanup ? required("OCI_BUCKET") : process.env.OCI_BUCKET;
const aws = apply || cleanup ? new AwsClient({
  accessKeyId: required("OCI_ACCESS_KEY"),
  secretAccessKey: required("OCI_SECRET_KEY"),
  service: "s3",
  region,
  retries: 2,
}) : null;

const objectUrl = (sourceBucket, path) =>
  `https://${namespace}.compat.objectstorage.${region}.oraclecloud.com/${encodeURIComponent(bucket)}/${["creatives", sourceBucket, ...path.split("/")].map(encodeURIComponent).join("/")}`;
const publicObjectUrl = (sourceBucket, path) =>
  `https://objectstorage.${region}.oraclecloud.com/n/${encodeURIComponent(namespace)}/b/${encodeURIComponent(bucket)}/o/${["creatives", sourceBucket, ...path.split("/")].map(encodeURIComponent).join("/")}`;
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

async function listObjects(sourceBucket, prefix = "") {
  const objects = [];
  for (let offset = 0; ; offset += 100) {
    const { data, error } = await supabase.storage.from(sourceBucket).list(prefix, { limit: 100, offset, sortBy: { column: "name", order: "asc" } });
    if (error) throw new Error(`Could not list ${sourceBucket}/${prefix}: ${error.message}`);
    for (const entry of data || []) {
      const path = prefix ? `${prefix}/${entry.name}` : entry.name;
      if (entry.id) objects.push({ sourceBucket, path, size: Number(entry.metadata?.size || 0) });
      else objects.push(...await listObjects(sourceBucket, path));
    }
    if (!data || data.length < 100) break;
  }
  return objects;
}

async function verifyAndCopy(object) {
  const { sourceBucket, path } = object;
  const { data, error } = await supabase.storage.from(sourceBucket).download(path);
  if (error || !data) throw new Error(`Could not read ${sourceBucket}/${path}: ${error?.message || "empty object"}`);
  const bytes = new Uint8Array(await data.arrayBuffer());
  const destination = objectUrl(sourceBucket, path);
  let response = await aws.fetch(destination, { method: "GET" });
  if (response.status === 404) {
    const uploaded = await aws.fetch(destination, {
      method: "PUT",
      headers: { "content-type": data.type || "application/octet-stream", "cache-control": "public, max-age=900" },
      body: bytes,
    });
    if (!uploaded.ok) throw new Error(`OCI upload failed for ${sourceBucket}/${path} (${uploaded.status}).`);
    response = await aws.fetch(destination, { method: "GET" });
  }
  if (!response.ok) throw new Error(`OCI verification download failed for ${sourceBucket}/${path} (${response.status}).`);
  const copied = new Uint8Array(await response.arrayBuffer());
  if (sha256(bytes) !== sha256(copied)) throw new Error(`OCI verification mismatch for ${sourceBucket}/${path}.`);
  const anonymous = await fetch(publicObjectUrl(sourceBucket, path), { method: "HEAD" });
  if (!anonymous.ok) throw new Error(`Public OCI URL is inaccessible for ${sourceBucket}/${path} (${anonymous.status}).`);
  return bytes.byteLength;
}

const oldCreatives = await listObjects("creative-media");
const productReferences = await listObjects("product-assets");
const size = (objects) => `${(objects.reduce((total, object) => total + object.size, 0) / 1024 / 1024).toFixed(1)} MiB`;
console.log(`Creative-media to destroy: ${oldCreatives.length} objects (${size(oldCreatives)}).`);
console.log(`Product-assets to migrate: ${productReferences.length} objects (${size(productReferences)}).`);
if (!apply && !cleanup && !destroyCreatives) {
  console.log("Dry run only. --apply copies product references; --destroy-creatives deletes only old creative-media objects.");
  process.exit(0);
}

if (destroyCreatives) {
  const paths = new Set(oldCreatives.map(({ path }) => path));
  const referencedAssets = [];
  for (let offset = 0; ; offset += 1000) {
    const { data, error } = await supabase.from("media_assets").select("id,storage_path,status").eq("storage_bucket", "creative-media").range(offset, offset + 999);
    if (error) throw new Error(`Could not audit creative records: ${error.message}`);
    referencedAssets.push(...(data || []).filter(({ storage_path }) => paths.has(storage_path)));
    if (!data || data.length < 1000) break;
  }
  console.log(`${referencedAssets.length} media-asset records refer to the creative files being destroyed.`);
  const assetIds = referencedAssets.map(({ id }) => id);
  for (let start = 0; start < assetIds.length; start += 100) {
    const { data: variants, error: variantError } = await supabase.from("platform_variants").select("id").in("selected_media_asset_id", assetIds.slice(start, start + 100));
    if (variantError) throw new Error(`Could not audit selected media: ${variantError.message}`);
    const variantIds = (variants || []).map(({ id }) => id);
    if (!variantIds.length) continue;
    const [schedules, jobs] = await Promise.all([
      supabase.from("schedules").select("id").in("platform_variant_id", variantIds).eq("status", "scheduled").limit(1),
      supabase.from("publish_jobs").select("id").in("platform_variant_id", variantIds).in("state", ["queued", "running", "waiting_external", "retrying"]).limit(1),
    ]);
    if (schedules.error || jobs.error) throw new Error(`Could not audit active publishing work: ${schedules.error?.message || jobs.error?.message}`);
    if (schedules.data?.length || jobs.data?.length) throw new Error("Old creative media is still selected by an active schedule or publish job. Cancel or finish it before deletion.");
  }
  for (const { path } of oldCreatives) {
    const { error } = await supabase.from("media_assets").delete().eq("storage_bucket", "creative-media").eq("storage_path", path);
    if (error) throw new Error(`Could not remove creative metadata for ${path}: ${error.message}`);
  }
  for (const object of oldCreatives) {
    const { error } = await supabase.storage.from("creative-media").remove([object.path]);
    if (error) throw new Error(`Could not remove creative-media/${object.path}: ${error.message}`);
  }
  console.log(`Destroyed ${oldCreatives.length} legacy creative-media objects and their media-asset records. Product-assets were untouched.`);
  process.exit(0);
}

let transferred = 0;
for (const [index, object] of productReferences.entries()) {
  transferred += await verifyAndCopy(object);
  console.log(`Verified ${index + 1}/${productReferences.length}: ${object.sourceBucket}/${object.path}`);
}
console.log(`Verified ${productReferences.length} product objects (${(transferred / 1024 / 1024).toFixed(1)} MiB) in OCI.`);

if (cleanup) {
  for (const [index, object] of productReferences.entries()) {
    const { error } = await supabase.storage.from(object.sourceBucket).remove([object.path]);
    if (error) throw new Error(`Could not remove legacy ${object.sourceBucket}/${object.path}: ${error.message}`);
    console.log(`Removed legacy product copy ${index + 1}/${productReferences.length}.`);
  }
  console.log("Legacy Supabase product references removed after OCI verification.");
}
