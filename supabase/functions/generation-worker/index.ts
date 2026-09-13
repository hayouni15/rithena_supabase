import { createClient } from "npm:@supabase/supabase-js@2";
import { creativeBriefPrompt, parseCreativeBrief, type CreativeBrief } from "./creative.ts";
import { selectMusic } from "./music.ts";
import { runQualityChecks } from "./quality.ts";

type Job = {
  id: string; organization_id: string; brand_id: string; content_item_id: string;
  type: "image" | "video" | "copy" | "qa"; state: string; model: string; external_job_id: string | null;
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

function savedBrief(job: Job) {
  const value = job.output?.creativeBrief;
  return value && typeof value === "object" ? value as CreativeBrief : null;
}

async function contentFormat(db: DatabaseClient, job: Job) {
  const supplied = job.input?.contentFormat;
  if (typeof supplied === "string" && ["image", "carousel", "short_video", "text"].includes(supplied)) return supplied;
  const result = await db.from("content_items").select("format").eq("id", job.content_item_id).eq("organization_id", job.organization_id).single();
  if (result.error || !result.data?.format) throw new Error("The planned content format is unavailable");
  job.input = { ...job.input, contentFormat: result.data.format };
  return String(result.data.format);
}

async function generateCreativeBrief(job: Job, token: string) {
  const project = env("GOOGLE_CLOUD_PROJECT");
  const location = Deno.env.get("GOOGLE_CLOUD_LOCATION") || "global";
  const model = Deno.env.get("CREATIVE_GEMINI_MODEL") || Deno.env.get("STRATEGY_GEMINI_MODEL") || "gemini-2.5-flash";
  const result = await vertex(`projects/${project}/locations/${location}/publishers/google/models/${model}:generateContent`, token, {
    contents: [{ role: "user", parts: [{ text: creativeBriefPrompt({ type: job.type === "video" ? "video" : "image", input: job.input }) }] }],
    generationConfig: { responseMimeType: "application/json", temperature: 0.85, maxOutputTokens: 8192 },
  });
  const text = (result.candidates?.[0]?.content?.parts || []).map((part: { text?: string }) => part.text || "").join("");
  return parseCreativeBrief(text);
}

async function savePlatformCopy(db: DatabaseClient, job: Job, assetId: string, brief: CreativeBrief, format: string) {
  const platforms = ((job.input?.strategy as Record<string, unknown> | undefined)?.platforms || []) as string[];
  const video = format === "short_video";
  for (const platform of platforms) {
    const variant = await db.from("platform_variants").upsert({
      organization_id: job.organization_id, content_item_id: job.content_item_id, platform, format,
      status: "ready", aspect_ratio: video ? "9:16" : "4:5", duration_seconds: video ? 8 : null,
      selected_media_asset_id: assetId, platform_config: { generatedBy: "n8n-parity-v1" },
    }, { onConflict: "content_item_id,platform" }).select("id").single();
    if (variant.error) throw new Error(`Platform variant failed: ${variant.error.message}`);
    const hashtags = brief.social_post.hashtags?.[platform] || [];
    const { data: priorCopies, error: priorCopiesError } = await db.from("post_copies").select("version").eq("platform_variant_id", variant.data.id).eq("locale", "en").order("version", { ascending: false }).limit(1);
    if (priorCopiesError) throw new Error(`Platform copy version lookup failed: ${priorCopiesError.message}`);
    const version = (priorCopies?.[0]?.version || 0) + 1;
    const deselect = await db.from("post_copies").update({ is_selected: false }).eq("platform_variant_id", variant.data.id).eq("locale", "en").eq("is_selected", true);
    if (deselect.error) throw new Error(`Platform copy selection failed: ${deselect.error.message}`);
    const copy = await db.from("post_copies").insert({
      organization_id: job.organization_id, platform_variant_id: variant.data.id, locale: "en", version, is_selected: true,
      headline: brief.text_overlay.headline.text, subhead: brief.text_overlay.subhead.text,
      caption: brief.social_post.caption, hashtags, call_to_action: brief.text_overlay.cta.text,
      title: platform === "youtube" ? brief.social_post.titles?.youtube : platform === "tiktok" ? brief.social_post.titles?.tiktok : null,
    });
    if (copy.error) throw new Error(`Platform copy failed: ${copy.error.message}`);
  }
}

async function checkpoint(db: DatabaseClient, job: Job, worker: string, stage: string, progress: number, state: string, output: Record<string, unknown> = {}, externalId?: string, retryAfter?: number, errorCode?: string, errorMessage?: string) {
  const { error } = await db.rpc("checkpoint_generation_job", { p_job_id: job.id, p_worker_id: worker, p_stage: stage, p_progress: progress, p_state: state, p_output: output, p_external_job_id: externalId || null, p_retry_after_seconds: retryAfter || null, p_error_code: errorCode || null, p_error_message: errorMessage || null });
  if (error) throw new Error(`Checkpoint failed: ${error.message}`);
}

async function storeAsset(db: DatabaseClient, job: Job, bytes: Uint8Array, mimeType: string, providerId?: string, options: { suffix?: string; assetType?: string; metadata?: Record<string, unknown> } = {}) {
  const extension = mimeType === "video/mp4" ? "mp4" : mimeType === "image/jpeg" ? "jpg" : mimeType === "image/webp" ? "webp" : "png";
  const path = `${job.organization_id}/${job.content_item_id}/${job.id}${options.suffix || ""}.${extension}`;
  const upload = await db.storage.from("creative-media").upload(path, bytes, { contentType: mimeType, upsert: false });
  if (upload.error && !upload.error.message.toLowerCase().includes("already exists")) throw new Error(`Storage upload failed: ${upload.error.message}`);
  const asset = { organization_id: job.organization_id, content_item_id: job.content_item_id, asset_type: options.assetType || job.type, origin: "generated", status: "ready", storage_bucket: "creative-media", storage_path: path, mime_type: mimeType, file_size_bytes: bytes.byteLength, provider: "google-vertex-ai", provider_asset_id: providerId || null, metadata: { model: job.model, generationJobId: job.id, pipeline: strategy(job).pipeline, ...(options.metadata || {}) } };
  const inserted = await db.from("media_assets").insert(asset).select("id").maybeSingle();
  if (inserted.error && inserted.error.code !== "23505") throw new Error(`Media record failed: ${inserted.error.message}`);
  if (inserted.data) return inserted.data.id as string;
  const existing = await db.from("media_assets").select("id").eq("storage_bucket", "creative-media").eq("storage_path", path).single();
  if (existing.error) throw new Error(`Media record lookup failed: ${existing.error.message}`);
  return existing.data.id as string;
}

async function completeQa(db: DatabaseClient, job: Job, assetId: string, brief: CreativeBrief, media: { mimeType: string; bytes: number; width?: number | null; height?: number | null; durationSeconds?: number | null }) {
  const revision = Number(job.input?.contentRevision);
  if (!Number.isSafeInteger(revision) || revision < 1) throw new Error("Generation job is missing its content revision");
  const checks = runQualityChecks({ ...job, type: media.mimeType.startsWith("video/") ? "video" : "image" }, brief, media);
  const result = await db.rpc("complete_content_qa", {
    p_content_item_id: job.content_item_id, p_expected_revision: revision,
    p_media_asset_id: assetId, p_checks: checks,
  });
  if (result.error) throw new Error(`Quality gate failed: ${result.error.message}`);
  return checks;
}

async function generateImage(db: DatabaseClient, job: Job, worker: string, token: string) {
  const format = await contentFormat(db, job);
  if (format === "carousel") return generateCarousel(db, job, worker, token);
  const project = env("GOOGLE_CLOUD_PROJECT"); const location = Deno.env.get("GOOGLE_CLOUD_LOCATION") || "global";
  const model = job.model || Deno.env.get("IMAGE_GEMINI_MODEL") || "gemini-3.1-flash-image";
  const brief = savedBrief(job) || await generateCreativeBrief(job, token);
  const typography = brief.text_overlay;
  const imagePrompt = `${brief.media_prompt}\n\nRender only this exact copy with correct spelling: headline “${typography.headline.text}”; supporting line “${typography.subhead.text}”; CTA “${typography.cta.text}”. ${brief.negative_prompt ? `Avoid: ${brief.negative_prompt}` : ""}`;
  const result = await vertex(`projects/${project}/locations/${location}/publishers/google/models/${model}:generateContent`, token, { contents: [{ role: "user", parts: [{ text: imagePrompt }] }], generationConfig: { responseModalities: ["TEXT", "IMAGE"], imageConfig: { aspectRatio: "4:5" } } });
  const part = result.candidates?.[0]?.content?.parts?.find((candidate: Record<string, unknown>) => (candidate.inlineData as { mimeType?: string } | undefined)?.mimeType?.startsWith("image/"));
  if (!part?.inlineData?.data) throw new Error("Gemini returned no image data");
  const bytes = decodeBase64(part.inlineData.data); const assetId = await storeAsset(db, job, bytes, part.inlineData.mimeType || "image/png", result.responseId);
  await savePlatformCopy(db, job, assetId, brief, format);
  const qaChecks = await completeQa(db, job, assetId, brief, { mimeType: part.inlineData.mimeType || "image/png", bytes: bytes.byteLength });
  await checkpoint(db, job, worker, "qa_complete", 100, "succeeded", { mediaAssetId: assetId, creativeBrief: brief, qaChecks });
}

async function generateCarousel(db: DatabaseClient, job: Job, worker: string, token: string) {
  const project = env("GOOGLE_CLOUD_PROJECT"); const location = Deno.env.get("GOOGLE_CLOUD_LOCATION") || "global";
  const model = job.model || Deno.env.get("IMAGE_GEMINI_MODEL") || "gemini-3.1-flash-image";
  const brief = savedBrief(job) || await generateCreativeBrief(job, token);
  const slides = brief.carousel_slides;
  if (!Array.isArray(slides) || slides.length !== 4 || slides.some((slide) => !slide.headline || !slide.media_prompt)) throw new Error("Creative director returned an incomplete four-slide carousel");
  const completed = Array.isArray(job.output?.carouselAssetIds) ? job.output.carouselAssetIds.filter((id): id is string => typeof id === "string") : [];
  const index = completed.length;
  if (index >= slides.length) throw new Error("Carousel checkpoint contains too many slides");
  const slide = slides[index];
  const suffix = `-slide-${index + 1}`;
  const extensionCandidates = ["png", "jpg", "webp"];
  let assetId = ""; let mimeType = "image/png"; let byteLength = 0;
  for (const extension of extensionCandidates) {
    const path = `${job.organization_id}/${job.content_item_id}/${job.id}${suffix}.${extension}`;
    const existing = await db.from("media_assets").select("id,mime_type,file_size_bytes").eq("storage_bucket", "creative-media").eq("storage_path", path).maybeSingle();
    if (existing.error) throw new Error(`Carousel resume lookup failed: ${existing.error.message}`);
    if (existing.data) { assetId = existing.data.id; mimeType = existing.data.mime_type || mimeType; byteLength = Number(existing.data.file_size_bytes || 0); break; }
  }
  if (!assetId) {
    const prompt = `${slide.media_prompt}\n\nThis is slide ${index + 1} of 4 in one coherent carousel. Render only this exact copy with correct spelling: headline “${slide.headline}”; supporting line “${slide.body || ""}”. Maintain consistent brand palette, subject, lighting, typography, and visual language across the series. ${brief.negative_prompt ? `Avoid: ${brief.negative_prompt}` : ""}`;
    const result = await vertex(`projects/${project}/locations/${location}/publishers/google/models/${model}:generateContent`, token, { contents: [{ role: "user", parts: [{ text: prompt }] }], generationConfig: { responseModalities: ["TEXT", "IMAGE"], imageConfig: { aspectRatio: "4:5" } } });
    const part = result.candidates?.[0]?.content?.parts?.find((candidate: Record<string, unknown>) => (candidate.inlineData as { mimeType?: string } | undefined)?.mimeType?.startsWith("image/"));
    if (!part?.inlineData?.data) throw new Error(`Gemini returned no image data for carousel slide ${index + 1}`);
    const bytes = decodeBase64(part.inlineData.data); mimeType = part.inlineData.mimeType || "image/png"; byteLength = bytes.byteLength;
    assetId = await storeAsset(db, job, bytes, mimeType, result.responseId, { suffix, assetType: "carousel_slide", metadata: { slideIndex: index + 1, slideCount: slides.length } });
  }
  const carouselAssetIds = [...completed, assetId];
  if (carouselAssetIds.length < slides.length) {
    await checkpoint(db, job, worker, `carousel_slide_${index + 1}_complete`, 15 + carouselAssetIds.length * 18, "waiting_external", { creativeBrief: brief, carouselAssetIds }, undefined, 1);
    return;
  }
  await savePlatformCopy(db, job, carouselAssetIds[0], brief, "carousel");
  const qaChecks = await completeQa(db, job, assetId, brief, { mimeType, bytes: byteLength });
  await checkpoint(db, job, worker, "qa_complete", 100, "succeeded", { mediaAssetId: carouselAssetIds[0], carouselAssetIds, creativeBrief: brief, qaChecks });
}

async function generateCopy(db: DatabaseClient, job: Job, worker: string, token: string) {
  const sourceId = typeof job.input?.sourceMediaAssetId === "string" ? job.input.sourceMediaAssetId : "";
  if (!sourceId) throw new Error("Copy-only revision is missing its source media asset");
  const asset = await db.from("media_assets").select("id,mime_type,file_size_bytes,width,height,duration_seconds").eq("id", sourceId).eq("content_item_id", job.content_item_id).eq("organization_id", job.organization_id).eq("status", "ready").maybeSingle();
  if (asset.error || !asset.data) throw new Error("The source media asset is no longer available for a copy-only revision");
  const brief = await generateCreativeBrief(job, token);
  await savePlatformCopy(db, job, asset.data.id, brief, await contentFormat(db, job));
  const qaChecks = await completeQa(db, job, asset.data.id, brief, {
    mimeType: asset.data.mime_type || "image/png", bytes: Number(asset.data.file_size_bytes || 0),
    width: asset.data.width, height: asset.data.height,
    durationSeconds: asset.data.duration_seconds === null ? null : Number(asset.data.duration_seconds),
  });
  await checkpoint(db, job, worker, "qa_complete", 100, "succeeded", { mediaAssetId: asset.data.id, creativeBrief: brief, qaChecks, regenerationMode: "copy" });
}

async function runManualCopyQa(db: DatabaseClient, job: Job, worker: string) {
  const sourceId = typeof job.input?.sourceMediaAssetId === "string" ? job.input.sourceMediaAssetId : "";
  const platform = typeof job.input?.editedPlatform === "string" ? job.input.editedPlatform : "";
  if (!sourceId || !platform) throw new Error("Manual copy QA is missing its source context");
  const [asset, variant] = await Promise.all([
    db.from("media_assets").select("id,mime_type,file_size_bytes,width,height,duration_seconds").eq("id",sourceId).eq("content_item_id",job.content_item_id).eq("status","ready").single(),
    db.from("platform_variants").select("post_copies(headline,subhead,caption,hashtags,call_to_action,title,is_selected,version)").eq("content_item_id",job.content_item_id).eq("platform",platform).single(),
  ]);
  if (asset.error || variant.error || !asset.data || !variant.data) throw new Error("Manual copy QA resources are unavailable");
  const copy = [...(variant.data.post_copies || [])].sort((a: {is_selected:boolean;version:number},b: {is_selected:boolean;version:number}) => Number(b.is_selected)-Number(a.is_selected)||b.version-a.version)[0];
  if (!copy) throw new Error("Manual copy QA found no selected copy");
  const brief: CreativeBrief = { media_prompt:"existing media", negative_prompt:"", audio_cue:"", text_overlay:{ layout:"bottom_minimal", headline:{text:copy.headline||"",in_time:0.5,out_time:5.5}, subhead:{text:copy.subhead||"",in_time:2.2,out_time:6.5}, cta:{text:copy.call_to_action||"",in_time:6,out_time:8} }, social_post:{ caption:copy.caption||"", hashtags:{[platform]:copy.hashtags||[]}, titles:{youtube:platform==="youtube"?(copy.title||""):"",tiktok:platform==="tiktok"?(copy.title||""):""} } };
  const media = { mimeType:asset.data.mime_type||"image/png", bytes:Number(asset.data.file_size_bytes||0), width:asset.data.width, height:asset.data.height, durationSeconds:asset.data.duration_seconds===null?null:Number(asset.data.duration_seconds) };
  const qaChecks = await completeQa(db,job,asset.data.id,brief,media);
  await checkpoint(db,job,worker,"qa_complete",100,"succeeded",{mediaAssetId:asset.data.id,qaChecks,regenerationMode:"manual_copy"});
}

async function downloadGcs(uri: string, token: string) {
  const match = uri.match(/^gs:\/\/([^/]+)\/(.+)$/); if (!match) throw new Error("Veo returned an invalid storage URI");
  const response = await fetch(`https://storage.googleapis.com/storage/v1/b/${match[1]}/o/${encodeURIComponent(match[2])}?alt=media`, { headers: { authorization: `Bearer ${token}` } });
  if (!response.ok) throw new Error(`Veo video download failed (${response.status})`);
  const length = Number(response.headers.get("content-length") || 0);
  if (length > 80_000_000) throw new Error("Veo returned a video larger than the 80 MB processing limit");
  if (!response.body) throw new Error("Veo returned an empty video stream");
  return response.body;
}

async function removeGcs(uri: string, token: string) {
  const match = uri.match(/^gs:\/\/([^/]+)\/(.+)$/); if (!match) return;
  const response = await fetch(`https://storage.googleapis.com/storage/v1/b/${match[1]}/o/${encodeURIComponent(match[2])}`, { method: "DELETE", headers: { authorization: `Bearer ${token}` } });
  if (!response.ok && response.status !== 404) console.warn("veo_output_cleanup_failed", { status: response.status });
}

async function recordVideoAsset(db: DatabaseClient, job: Job, path: string, bytes: number) {
  const asset = { organization_id: job.organization_id, content_item_id: job.content_item_id, asset_type: job.type, origin: "generated", status: "ready", storage_bucket: "creative-media", storage_path: path, mime_type: "video/mp4", file_size_bytes: bytes, provider: "google-vertex-ai", provider_asset_id: job.external_job_id, metadata: { model: job.model, generationJobId: job.id, pipeline: strategy(job).pipeline } };
  const inserted = await db.from("media_assets").insert(asset).select("id").maybeSingle();
  if (inserted.error && inserted.error.code !== "23505") throw new Error(`Media record failed: ${inserted.error.message}`);
  if (inserted.data) return inserted.data.id as string;
  const existing = await db.from("media_assets").select("id").eq("storage_bucket", "creative-media").eq("storage_path", path).single();
  if (existing.error) throw new Error(`Media record lookup failed: ${existing.error.message}`);
  return existing.data.id as string;
}

async function composeVideo(db: DatabaseClient, job: Job, rawVideo: Uint8Array | ReadableStream<Uint8Array>, brief: CreativeBrief) {
  const composerUrl = env("MEDIA_COMPOSER_URL").replace(/\/$/, "");
  const composerSecret = env("MEDIA_COMPOSER_SECRET");
  const rawPath = `${job.organization_id}/${job.content_item_id}/${job.id}.raw.mp4`;
  const finalPath = `${job.organization_id}/${job.content_item_id}/${job.id}.mp4`;
  const upload = await db.storage.from("creative-media").upload(rawPath, rawVideo, { contentType: "video/mp4", upsert: true, duplex: "half" });
  if (upload.error) throw new Error(`Raw video upload failed: ${upload.error.message}`);
  try {
    const [signed, output] = await Promise.all([
      db.storage.from("creative-media").createSignedUrl(rawPath, 900),
      db.storage.from("creative-media").createSignedUploadUrl(finalPath, { upsert: true }),
    ]);
    if (signed.error || !signed.data?.signedUrl) throw new Error(`Raw video signing failed: ${signed.error?.message || "unknown"}`);
    if (output.error || !output.data?.signedUrl) throw new Error(`Final video upload signing failed: ${output.error?.message || "unknown"}`);
    const brand = (job.input?.brandBrain || {}) as Record<string, unknown>;
    const response = await fetch(`${composerUrl}/compose`, {
      method: "POST", signal: AbortSignal.timeout(140_000),
      headers: { authorization: `Bearer ${composerSecret}`, "content-type": "application/json" },
      body: JSON.stringify({
        sourceUrl: signed.data.signedUrl, outputUploadUrl: output.data.signedUrl, musicUrl: selectMusic(brief, job.id), durationSeconds: 8,
        brandName: String(brand.name || ""), logoUrl: String((brand.visual as Record<string, unknown> | undefined)?.logoUrl || ""),
        layout: brief.text_overlay.layout, overlays: [brief.text_overlay.headline, brief.text_overlay.subhead, brief.text_overlay.cta],
      }),
    });
    if (!response.ok) throw new Error(`Media composer failed (${response.status}): ${(await response.text()).slice(0, 300)}`);
    const result = await response.json() as { bytes?: number };
    if (!Number.isSafeInteger(result.bytes) || result.bytes < 1) throw new Error("Media composer returned an invalid output size");
    return { path: finalPath, bytes: result.bytes };
  } finally {
    const removed = await db.storage.from("creative-media").remove([rawPath]);
    if (removed.error) console.warn("raw_video_cleanup_failed", { jobId: job.id, message: removed.error.message });
  }
}

async function handleVideo(db: DatabaseClient, job: Job, worker: string, token: string) {
  const project = env("GOOGLE_CLOUD_PROJECT"); const location = Deno.env.get("VEO_LOCATION") || "us-central1";
  const model = job.model || Deno.env.get("VEO_MODEL") || "veo-3.1-generate-001";
  const modelPath = `projects/${project}/locations/${location}/publishers/google/models/${model}`;
  if (!job.external_job_id) {
    const brief = savedBrief(job) || await generateCreativeBrief(job, token);
    const storageUri = env("VEO_OUTPUT_GCS_URI");
    if (!/^gs:\/\/[^/]+\/?$/.test(storageUri)) throw new Error("VEO_OUTPUT_GCS_URI must be a Cloud Storage bucket URI such as gs://bucket-name");
    const result = await vertex(`${modelPath}:predictLongRunning`, token, { instances: [{ prompt: brief.media_prompt }], parameters: { aspectRatio: "9:16", durationSeconds: 8, sampleCount: 1, resolution: "1080p", generateAudio: false, negativePrompt: brief.negative_prompt, storageUri } });
    if (!result.name) throw new Error("Veo returned no operation name");
    await checkpoint(db, job, worker, "provider_processing", 35, "waiting_external", { submittedAt: new Date().toISOString(), creativeBrief: brief }, result.name, 30);
    return;
  }
  const result = await vertex(`${modelPath}:fetchPredictOperation`, token, { operationName: job.external_job_id });
  if (!result.done) { await checkpoint(db, job, worker, "provider_processing", 55, "waiting_external", {}, job.external_job_id, 30); return; }
  if (result.error) throw new Error(`Veo generation failed: ${result.error.message || result.error.code}`);
  const videos = result.response?.videos || result.response?.predictions || [];
  if (!videos.length) throw new Error("Veo returned no video");
  const inline = videos[0].bytesBase64Encoded;
  const gcsUri = typeof videos[0].gcsUri === "string" ? videos[0].gcsUri : "";
  if (inline) throw new Error("Veo returned inline video data instead of the required GCS output; retry this job with a new operation");
  const rawVideo = await downloadGcs(gcsUri, token);
  const brief = savedBrief(job); if (!brief) throw new Error("The saved creative brief is missing");
  const video = await composeVideo(db, job, rawVideo, brief);
  const assetId = await recordVideoAsset(db, job, video.path, video.bytes);
  await savePlatformCopy(db, job, assetId, brief, "short_video");
  const qaChecks = await completeQa(db, job, assetId, brief, { mimeType: "video/mp4", bytes: video.bytes, width: 1080, height: 1920, durationSeconds: 8 });
  await checkpoint(db, job, worker, "qa_complete", 100, "succeeded", { mediaAssetId: assetId, creativeBrief: brief, musicUrl: selectMusic(brief, job.id), qaChecks });
  if (gcsUri) await removeGcs(gcsUri, token);
}

async function normalizeQueuedModel(db: DatabaseClient, job: Job) {
  if (job.external_job_id) return;
  if (job.type === "qa") return;
  const configured = job.type === "image"
    ? (Deno.env.get("IMAGE_GEMINI_MODEL") || "gemini-3.1-flash-image")
    : job.type === "video" ? (Deno.env.get("VEO_MODEL") || "veo-3.1-generate-001")
      : (Deno.env.get("CREATIVE_GEMINI_MODEL") || Deno.env.get("STRATEGY_GEMINI_MODEL") || "gemini-2.5-flash");
  const obsolete = job.type === "image"
    ? job.model === "gemini-3.1-flash-image-preview"
    : job.type === "video" && (job.model === "veo-3.0-generate-001" || job.model === "veo-3.1-generate-preview");
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
  const claimed = await db.rpc("claim_next_generation_job", { p_worker_id: worker, p_lease_seconds: 300 });
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
    if (job.type === "qa") await runManualCopyQa(db,job,worker);
    else {
      const token = await accessToken();
      if (job.type === "image") await generateImage(db, job, worker, token);
      else if (job.type === "video") await handleVideo(db, job, worker, token);
      else if (job.type === "copy") await generateCopy(db, job, worker, token);
      else throw new Error(`Unsupported generation type: ${job.type}`);
    }
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
