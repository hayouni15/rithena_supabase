import type { CreativeBrief } from "./creative.ts";

type QualityJob = { type: "image" | "video"; input: Record<string, unknown> };
type CopyField = "headline" | "subhead" | "cta" | "caption" | "youtube_title" | "tiktok_title" | "hashtags";
export type QualityIssue = { code: string; message: string; correction: string; field?: CopyField; platform?: string; quote?: string; suggestion?: string };
export type QualityCheck = {
  checkType: "brand_accuracy" | "copy" | "visual" | "video" | "policy";
  passed: boolean;
  issues: QualityIssue[];
  action: "accept" | "human_review";
  checker: "rithena-rules-v1";
};

const normalize = (value: unknown) => String(value || "").toLowerCase().replace(/[^a-z0-9%$]+/g, " ").trim();
const words = (value: string) => value.trim().split(/\s+/).filter(Boolean).length;
const issue = (code: string, message: string, correction: string, target: Partial<Pick<QualityIssue, "field" | "platform" | "quote" | "suggestion">> = {}): QualityIssue => ({ code, message, correction, ...target });
const checked = (checkType: QualityCheck["checkType"], issues: QualityIssue[]): QualityCheck => ({
  checkType, passed: issues.length === 0, issues,
  action: issues.length ? "human_review" : "accept", checker: "rithena-rules-v1",
});

function allCopy(brief: CreativeBrief) {
  return [brief.text_overlay.headline.text, brief.text_overlay.subhead.text,
    brief.text_overlay.cta.text, brief.social_post.caption,
    brief.social_post.titles?.youtube, brief.social_post.titles?.tiktok].filter(Boolean).join(" ");
}

const sentenceAround = (text: string, index: number) => {
  const start = Math.max(text.lastIndexOf(".", index - 1), text.lastIndexOf("!", index - 1), text.lastIndexOf("?", index - 1)) + 1;
  const endings = [text.indexOf(".", index), text.indexOf("!", index), text.indexOf("?", index)].filter((value) => value >= 0);
  const end = endings.length ? Math.min(...endings) + 1 : text.length;
  return text.slice(start, end).trim();
};

export function runQualityChecks(job: QualityJob, brief: CreativeBrief, media: {
  mimeType: string; bytes: number; width?: number | null; height?: number | null; durationSeconds?: number | null;
}): QualityCheck[] {
  const brain = (job.input.brandBrain || {}) as Record<string, unknown>;
  const strategy = (job.input.strategy || {}) as Record<string, unknown>;
  const copy = allCopy(brief);
  const normalizedCopy = normalize(copy);
  const brandIssues: QualityIssue[] = [];
  const copyIssues: QualityIssue[] = [];
  const mediaIssues: QualityIssue[] = [];
  const policyIssues: QualityIssue[] = [];
  const copyFields: Array<{ field: Exclude<CopyField, "hashtags">; value: string }> = [
    { field: "headline", value: brief.text_overlay.headline.text },
    { field: "subhead", value: brief.text_overlay.subhead.text },
    { field: "cta", value: brief.text_overlay.cta.text },
    { field: "caption", value: brief.social_post.caption },
    { field: "youtube_title", value: brief.social_post.titles?.youtube || "" },
    { field: "tiktok_title", value: brief.social_post.titles?.tiktok || "" },
  ];

  const brandName = normalize(brain.name);
  if (brandName && !normalizedCopy.includes(brandName)) brandIssues.push(issue(
    "brand_name_missing", "The generated copy does not identify the brand.", "Mention the brand naturally in the caption before approval.",
    { field: "caption", quote: brief.social_post.caption, suggestion: `Mention ${String(brain.name)} naturally in the caption without changing the claim.` },
  ));
  for (const phrase of (Array.isArray(brain.bannedPhrases) ? brain.bannedPhrases : [])) {
    const banned = normalize(phrase);
    if (!banned) continue;
    for (const field of copyFields.filter((entry) => normalize(entry.value).includes(banned))) brandIssues.push(issue(
      "banned_phrase", `The ${field.field.replaceAll("_", " ")} uses a banned phrase.`, "Remove or replace the banned wording.",
      { field: field.field, quote: String(phrase), suggestion: `Rewrite the ${field.field.replaceAll("_", " ")} without “${String(phrase)}” while preserving its meaning.` },
    ));
  }

  const headlineWords = words(brief.text_overlay.headline.text);
  const subheadWords = words(brief.text_overlay.subhead.text);
  const ctaWords = words(brief.text_overlay.cta.text);
  if (headlineWords < 3 || headlineWords > 6) copyIssues.push(issue("headline_length", "The headline is outside the 3–6 word reading budget.", "Rewrite the headline to 3–6 words.", { field: "headline", quote: brief.text_overlay.headline.text, suggestion: "Rewrite this headline to 3–6 specific words without adding a new claim." }));
  if (subheadWords > 14) copyIssues.push(issue("subhead_length", "The subhead exceeds 14 words.", "Shorten the subhead to 14 words or fewer.", { field: "subhead", quote: brief.text_overlay.subhead.text, suggestion: "Shorten this subhead to 14 words or fewer while preserving the verified benefit." }));
  if (ctaWords < 1 || ctaWords > 5) copyIssues.push(issue("cta_length", "The CTA is outside the 1–5 word reading budget.", "Use a specific CTA of 1–5 words.", { field: "cta", quote: brief.text_overlay.cta.text, suggestion: "Replace this with a specific 1–5 word action and destination." }));
  if (brief.social_post.caption.trim().split(/(?<=[.!?])\s+/).filter(Boolean).length > 5) copyIssues.push(issue("caption_length", "The caption exceeds five sentences.", "Reduce the caption to 3–5 short sentences.", { field: "caption", quote: brief.social_post.caption, suggestion: "Condense this caption to 3–5 short sentences without losing verified facts or the CTA." }));
  const expectedHashtags: Record<string, number> = { instagram: 10, tiktok: 10, youtube: 10, linkedin: 5 };
  const platforms = Array.isArray(strategy.platforms) ? strategy.platforms.map(String) : [];
  for (const platform of platforms) {
    const expected = expectedHashtags[platform];
    if (expected && (brief.social_post.hashtags?.[platform] || []).length !== expected) copyIssues.push(issue(
      "platform_hashtag_count", `${platform} requires ${expected} hashtags for this production format.`, `Provide exactly ${expected} relevant ${platform} hashtags.`,
      { field: "hashtags", platform, quote: (brief.social_post.hashtags?.[platform] || []).join(" "), suggestion: `Return exactly ${expected} relevant ${platform} hashtags; remove duplicates and unrelated tags.` },
    ));
  }

  if (media.bytes < (job.type === "video" ? 100_000 : 10_000)) mediaIssues.push(issue("media_too_small", "The media file is unexpectedly small and may be corrupt.", "Regenerate the asset and verify the exported file."));
  if (!media.mimeType.startsWith(`${job.type}/`)) mediaIssues.push(issue("media_type", `Expected ${job.type} media but received ${media.mimeType}.`, "Regenerate the asset in the planned format."));
  if (media.width && media.height) {
    const ratio = media.width / media.height;
    const expected = job.type === "video" ? 9 / 16 : 4 / 5;
    if (Math.abs(ratio - expected) > 0.03) mediaIssues.push(issue("aspect_ratio", "The exported media does not match the planned aspect ratio.", `Export a ${job.type === "video" ? "9:16" : "4:5"} asset.`));
  }
  if (job.type === "video" && media.durationSeconds && Math.abs(media.durationSeconds - 8) > 0.6) mediaIssues.push(issue("video_duration", "The finished video is outside the expected 8-second duration.", "Re-export an 8-second finished asset."));

  const facts = (Array.isArray(brain.verifiedFacts) ? brain.verifiedFacts : []) as Array<Record<string, unknown>>;
  const groundedText = normalize(facts.map((fact) => `${fact.key || ""} ${fact.value || ""}`).join(" "));
  // Policy checks deliberately target claims a reader could reasonably treat as
  // factual/commercial promises. Do not flag ordinary pain language such as
  // "costs time", "saves effort", or "pricing can be confusing".
  const sensitive = [
    /\$\s?\d[\d,]*(?:\.\d{1,2})?(?:\s*(?:cad|usd))?/i,
    /\b(?:price|pricing)\s*(?:is|starts?\s+at|from|of)\s*\$?\s*\d/i,
    /\b(?:save|saving|savings|discount|off)\s*(?:of\s*)?(?:\$\s*)?\d[\d,]*(?:\.\d+)?(?:%|\s*(?:cad|usd|dollars?))?/i,
    /\b\d+(?:\.\d+)?%\s*(?:more|less|faster|slower|increase|increased|decrease|decreased|reduction|reduced|growth|grow|saved|save|off)\b/i,
    /\b(?:guarantee(?:d)?|risk[- ]free|best|leading|number one|most trusted)\b/i,
    /\b(?:testimonial|customers?|clients?)\s+(?:say|love|report|saved|grew|achieved)\b/i,
    /\b(?:cure|treat|diagnose|legal advice|financial advice)\b/i,
    /\b(?:licensed|certified)\s+(?:financial|legal|medical|tax)\b/i,
  ];
  const seenPolicyIssues = new Set<string>();
  for (const field of copyFields) {
    for (const pattern of sensitive) {
      const match = field.value.match(pattern);
      if (!match || groundedText.includes(normalize(match[0]))) continue;
      const quote = sentenceAround(field.value, match.index || 0) || match[0];
      const key = `${field.field}:${quote}`;
      if (seenPolicyIssues.has(key)) continue;
      seenPolicyIssues.add(key);
      policyIssues.push(issue(
        "unverified_sensitive_claim", `The ${field.field.replaceAll("_", " ")} contains a sensitive claim that is not present in verified Brand Brain facts.`,
        "Remove the claim or verify the exact supporting fact in Brand Brain before approval.",
        { field: field.field, quote, suggestion: `Rewrite this ${field.field.replaceAll("_", " ")} without the unsupported claim “${match[0]}”, keeping only verified benefits.` },
      ));
    }
  }

  return [checked("brand_accuracy", brandIssues), checked("copy", copyIssues),
    checked(job.type === "video" ? "video" : "visual", mediaIssues), checked("policy", policyIssues)];
}
