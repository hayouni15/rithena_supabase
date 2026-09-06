import { createClient } from "npm:@supabase/supabase-js@2";

type Job = {
  id: string; organization_id: string; brand_id: string; content_item_id: string;
  type: "image" | "video"; state: string; model: string; external_job_id: string | null;
  attempt: number; max_attempts: number; progress: number; input: Record<string, unknown>; output: Record<string, unknown>;
};
type Credentials = { client_email: string; private_key: string };
// The project does not generate database typings for Edge Functions yet.
// deno-lint-ignore no-explicit-any
type DatabaseClient = any;

const env = (name: string) => { const value = Deno.env.get(name)?.trim(); if (!value) throw new Error(`${name} is missing`); return value; };
const base64Url = (value: Uint8Array | string) => {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  let binary = ""; for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
};
const decodeBase64 = (value: string) => Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
const json = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });

async function accessToken() {
  const credentials = JSON.parse(new TextDecoder().decode(decodeBase64(env("GOOGLE_VERTEX_CREDENTIALS_B64")))) as Credentials;
  const pem = credentials.private_key.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, "");
  const key = await crypto.subtle.importKey("pkcs8", decodeBase64(pem), { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const now = Math.floor(Date.now() / 1000);
  const unsigned = `${base64Url(JSON.stringify({ alg: "RS256", typ: "JWT" }))}.${base64Url(JSON.stringify({ iss: credentials.client_email, scope: "https://www.googleapis.com/auth/cloud-platform", aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600 }))}`;
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned));
  const response = await fetch("https://oauth2.googleapis.com/token", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: `${unsigned}.${base64Url(new Uint8Array(signature))}` }) });
  const payload = await response.json();
  if (!response.ok || !payload.access_token) throw new Error(`Google authentication failed (${response.status})`);
  return payload.access_token as string;
}

async function vertex(path: string, token: string, body: unknown) {
  const response = await fetch(`https://aiplatform.googleapis.com/v1/${path}`, { method: "POST", headers: { authorization: `Bearer ${token}`, "content-type": "application/json" }, body: JSON.stringify(body), signal: AbortSignal.timeout(110_000) });
  const payload = await response.json();
  if (!response.ok) throw new Error(`Vertex request failed (${response.status}): ${payload.error?.status || "unknown"} ${String(payload.error?.message || "").slice(0, 300)}`.trim());
  return payload;
}

function strategy(job: Job) {
  const input = job.input || {}; const value = (input.strategy || {}) as Record<string, unknown>;
  return { pipeline: String(input.pipeline || (job.type === "video" ? "veo_text_to_video" : "gemini_image")), title: String(value.title || ""), hook: String(value.hook || ""), concept: String(value.concept || ""), direction: String(value.creativeDirection || ""), cta: String(value.callToAction || "") };
}

function prompt(job: Job) {
  const item = strategy(job);
  return `Create premium, distinctive social creative for a real brand. Concept: ${item.concept}. Working title: ${item.title}. Hook: ${item.hook}. Art direction: ${item.direction}. CTA intent: ${item.cta}. Make one coherent scene with deliberate composition, realistic lighting, specific materials, and generous mobile safe zones. Do not render text, logos, watermarks, UI, buttons, or invented product claims.`;
}

async function checkpoint(db: DatabaseClient, job: Job, worker: string, stage: string, progress: number, state: string, output: Record<string, unknown> = {}, externalId?: string, retryAfter?: number, errorCode?: string, errorMessage?: string) {
  const { error } = await db.rpc("checkpoint_generation_job", { p_job_id: job.id, p_worker_id: worker, p_stage: stage, p_progress: progress, p_state: state, p_output: output, p_external_job_id: externalId || null, p_retry_after_seconds: retryAfter || null, p_error_code: errorCode || null, p_error_message: errorMessage || null });
  if (error) throw new Error(`Checkpoint failed: ${error.message}`);
}

async function storeAsset(db: DatabaseClient, job: Job, bytes: Uint8Array, mimeType: string, providerId?: string) {
  const extension = mimeType === "video/mp4" ? "mp4" : mimeType === "image/jpeg" ? "jpg" : mimeType === "image/webp" ? "webp" : "png";
  const path = `${job.organization_id}/${job.content_item_id}/${job.id}.${extension}`;
  const upload = await db.storage.from("creative-media").upload(path, bytes, { contentType: mimeType, upsert: false });
  if (upload.error && !upload.error.message.toLowerCase().includes("already exists")) throw new Error(`Storage upload failed: ${upload.error.message}`);
  const asset = { organization_id: job.organization_id, content_item_id: job.content_item_id, asset_type: job.type, origin: "generated", status: "ready", storage_bucket: "creative-media", storage_path: path, mime_type: mimeType, file_size_bytes: bytes.byteLength, provider: "google-vertex-ai", provider_asset_id: providerId || null, metadata: { model: job.model, generationJobId: job.id, pipeline: strategy(job).pipeline } };
  const inserted = await db.from("media_assets").insert(asset).select("id").maybeSingle();
  if (inserted.error && inserted.error.code !== "23505") throw new Error(`Media record failed: ${inserted.error.message}`);
  if (inserted.data) return inserted.data.id as string;
  const existing = await db.from("media_assets").select("id").eq("storage_bucket", "creative-media").eq("storage_path", path).single();
  if (existing.error) throw new Error(`Media record lookup failed: ${existing.error.message}`);
  return existing.data.id as string;
}

async function generateImage(db: DatabaseClient, job: Job, worker: string, token: string) {
  const project = env("GOOGLE_CLOUD_PROJECT"); const location = Deno.env.get("GOOGLE_CLOUD_LOCATION") || "global";
  const model = job.model || Deno.env.get("IMAGE_GEMINI_MODEL") || "gemini-3.1-flash-image";
  const result = await vertex(`projects/${project}/locations/${location}/publishers/google/models/${model}:generateContent`, token, { contents: [{ role: "user", parts: [{ text: prompt(job) }] }], generationConfig: { responseModalities: ["TEXT", "IMAGE"], imageConfig: { aspectRatio: "4:5" } } });
  const part = result.candidates?.[0]?.content?.parts?.find((candidate: Record<string, unknown>) => (candidate.inlineData as { mimeType?: string } | undefined)?.mimeType?.startsWith("image/"));
  if (!part?.inlineData?.data) throw new Error("Gemini returned no image data");
  const bytes = decodeBase64(part.inlineData.data); const assetId = await storeAsset(db, job, bytes, part.inlineData.mimeType || "image/png", result.responseId);
  await checkpoint(db, job, worker, "media_ready", 100, "succeeded", { mediaAssetId: assetId });
}

async function downloadGcs(uri: string, token: string) {
  const match = uri.match(/^gs:\/\/([^/]+)\/(.+)$/); if (!match) throw new Error("Veo returned an invalid storage URI");
  const response = await fetch(`https://storage.googleapis.com/storage/v1/b/${match[1]}/o/${encodeURIComponent(match[2])}?alt=media`, { headers: { authorization: `Bearer ${token}` } });
  if (!response.ok) throw new Error(`Veo video download failed (${response.status})`);
  return new Uint8Array(await response.arrayBuffer());
}

async function handleVideo(db: DatabaseClient, job: Job, worker: string, token: string) {
  const project = env("GOOGLE_CLOUD_PROJECT"); const location = Deno.env.get("VEO_LOCATION") || "us-central1";
  const model = job.model || Deno.env.get("VEO_MODEL") || "veo-3.1-generate-001";
  const modelPath = `projects/${project}/locations/${location}/publishers/google/models/${model}`;
  if (!job.external_job_id) {
    const result = await vertex(`${modelPath}:predictLongRunning`, token, { instances: [{ prompt: `${prompt(job)} Generate a cinematic vertical mobile video. Generate in vertical 9:16 portrait orientation for mobile. 8 seconds duration.` }], parameters: { aspectRatio: "9:16", durationSeconds: 8, sampleCount: 1 } });
    if (!result.name) throw new Error("Veo returned no operation name");
    await checkpoint(db, job, worker, "provider_processing", 35, "waiting_external", { submittedAt: new Date().toISOString() }, result.name, 30);
    return;
  }
  const result = await vertex(`${modelPath}:fetchPredictOperation`, token, { operationName: job.external_job_id });
  if (!result.done) { await checkpoint(db, job, worker, "provider_processing", 55, "waiting_external", {}, job.external_job_id, 30); return; }
  if (result.error) throw new Error(`Veo generation failed: ${result.error.message || result.error.code}`);
  const videos = result.response?.videos || result.response?.predictions || [];
  if (!videos.length) throw new Error("Veo returned no video");
  const bytes = videos[0].bytesBase64Encoded ? decodeBase64(videos[0].bytesBase64Encoded) : await downloadGcs(videos[0].gcsUri, token);
  const assetId = await storeAsset(db, job, bytes, "video/mp4", job.external_job_id);
  await checkpoint(db, job, worker, "media_ready", 100, "succeeded", { mediaAssetId: assetId });
}

async function normalizeQueuedModel(db: DatabaseClient, job: Job) {
  if (job.external_job_id) return;
  const configured = job.type === "image"
    ? (Deno.env.get("IMAGE_GEMINI_MODEL") || "gemini-3.1-flash-image")
    : (Deno.env.get("VEO_MODEL") || "veo-3.1-generate-001");
  const obsolete = job.type === "image"
    ? job.model === "gemini-3.1-flash-image-preview"
    : job.model === "veo-3.0-generate-001" || job.model === "veo-3.1-generate-preview";
  if (!obsolete || job.model === configured) return;
  const updated = await db.from("generation_jobs").update({ model: configured }).eq("id", job.id);
  if (updated.error) console.warn("job_model_update_failed", { jobId: job.id, message: updated.error.message });
  job.model = configured;
  console.log("job_model_normalized", { jobId: job.id, model: configured });
}

Deno.serve(async (request) => {
  const expected = Deno.env.get("CRON_SECRET");
  if (!expected || request.headers.get("authorization") !== `Bearer ${expected}`) return json({ error: "Unauthorized" }, 401);
  const worker = `edge:${crypto.randomUUID()}`;
  const db = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false } });
  const claimed = await db.rpc("claim_next_generation_job", { p_worker_id: worker, p_lease_seconds: 120 });
  if (claimed.error) { console.error("claim_failed", { message: claimed.error.message }); return json({ error: "Job claim failed" }, 500); }
  const job = claimed.data as Job | null;
  // A PostgreSQL function returning a composite type serializes SQL NULL as an
  // object with every field set to null. Check the primary key, not just the
  // object itself, before treating the claim as a real job.
  if (!job || typeof job.id !== "string" || !job.id) {
    console.log("queue_empty");
    return json({ ok: true, claimed: false });
  }
  console.log("job_claimed", { jobId: job.id, type: job.type, attempt: job.attempt, external: !!job.external_job_id });
  try {
    await normalizeQueuedModel(db, job);
    const token = await accessToken();
    if (job.type === "image") await generateImage(db, job, worker, token);
    else if (job.type === "video") await handleVideo(db, job, worker, token);
    else throw new Error(`Unsupported generation type: ${job.type}`);
    console.log("job_checkpointed", { jobId: job.id });
    return json({ ok: true, claimed: true, jobId: job.id });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Generation failed";
    console.error("job_failed", { jobId: job.id, attempt: job.attempt, message });
    const retry = job.attempt < job.max_attempts;
    try { await checkpoint(db, job, worker, retry ? "retry_scheduled" : "failed", job.progress || 0, retry ? "retrying" : "failed", {}, undefined, retry ? Math.min(900, 15 * 2 ** Math.max(0, job.attempt - 1)) : undefined, "generation_failed", message.slice(0, 500)); } catch (checkpointError) { console.error("failure_checkpoint_failed", { jobId: job.id, message: String(checkpointError) }); }
    return json({ error: "Generation failed", jobId: job.id, retrying: retry }, 500);
  }
});
