import type { CreativeBrief } from "./creative.ts";

export type ImageFieldOwnership = { field: "headline" | "subhead" | "cta" | "logo"; precision: "expressive" | "exact"; renderer: "model" | "rithena" };
export type ImageStrategy = { recipeId: string; recipeVersion: number; textStrategy: "ai_native" | "hybrid" | "structured_overlay"; fieldOwnership: ImageFieldOwnership[]; reason: string };

const ownership = {
  expressive: [
    { field: "headline", precision: "expressive", renderer: "model" }, { field: "subhead", precision: "expressive", renderer: "model" },
    { field: "cta", precision: "exact", renderer: "rithena" }, { field: "logo", precision: "exact", renderer: "rithena" },
  ] as ImageFieldOwnership[],
  structured: [
    { field: "headline", precision: "exact", renderer: "rithena" }, { field: "subhead", precision: "exact", renderer: "rithena" },
    { field: "cta", precision: "exact", renderer: "rithena" }, { field: "logo", precision: "exact", renderer: "rithena" },
  ] as ImageFieldOwnership[],
};

export function fallbackImageStrategy(input: Record<string, unknown>): ImageStrategy {
  const planned = (input.strategy || {}) as Record<string, unknown>;
  const brand = (input.brandBrain || {}) as Record<string, unknown>;
  const context = [planned.title, planned.hook, planned.concept, planned.creativeDirection, planned.callToAction].filter(Boolean).join(" ").toLowerCase();
  const exact = String(input.contentFormat || "") === "carousel" || /(?:https?:\/\/|www\.|\b\d+(?:[.,]\d+)?%?\b|[$€£]\s?\d|\b(?:price|pricing|statistic|statistics|facts|steps|checklist|comparison|before\s*(?:\/|and)\s*after|testimonial|phone|sku|disclaimer)\b)/i.test(context);
  if (exact) return { recipeId: "three-key-facts", recipeVersion: 1, textStrategy: "structured_overlay", fieldOwnership: ownership.structured, reason: "Precision-sensitive content uses deterministic typography." };
  if (/\b(editorial|provocative|provocation|contrarian|bold statement|poster|campaign art|meme|manifesto|typograph)/i.test(context)) return { recipeId: "editorial-provocation", recipeVersion: 1, textStrategy: "ai_native", fieldOwnership: ownership.expressive, reason: "Integrated typography is part of the visual idea." };
  const goals = Array.isArray(brand.goals) ? brand.goals : [];
  const product = /\b(product|offer|launch|showcase|feature|collection|service|book|shop|buy|lead|demo)\b/i.test(context) || goals.some((goal) => ["promote_products", "get_leads"].includes(String(goal)));
  return { recipeId: "product-hero", recipeVersion: 1, textStrategy: "hybrid", fieldOwnership: ownership.expressive, reason: product ? "Product art direction uses exact conversion overlays." : "Hybrid is the safe fallback." };
}

export function requestedImageStrategy(input: Record<string, unknown>): ImageStrategy {
  const fallback = fallbackImageStrategy(input); const value = input.imageStrategy;
  if (!value || typeof value !== "object" || Array.isArray(value)) return fallback;
  const candidate = value as Record<string, unknown>;
  if (typeof candidate.recipeId !== "string" || !Number.isInteger(candidate.recipeVersion) || !["ai_native", "hybrid", "structured_overlay"].includes(String(candidate.textStrategy)) || !Array.isArray(candidate.fieldOwnership)) return fallback;
  return { recipeId: candidate.recipeId, recipeVersion: Number(candidate.recipeVersion), textStrategy: candidate.textStrategy as ImageStrategy["textStrategy"], fieldOwnership: candidate.fieldOwnership as ImageFieldOwnership[], reason: typeof candidate.reason === "string" ? candidate.reason : fallback.reason };
}

export function generationMode(input: Record<string, unknown>) {
  return input.regenerationMode === "update_design" ? "update_design" : input.regenerationMode === "reimagine" ? "reimagine" : "initial";
}

export function preservationFor(mode: string) {
  if (mode === "update_design") return ["subject", "palette", "lighting", "visual_identity", "composition_character", "approved_copy"];
  if (mode === "reimagine") return ["brand_constraints", "approved_message", "exact_fields"];
  return ["brand_constraints", "approved_copy", "recipe_direction"];
}

export function imageGenerationPrompt(brief: CreativeBrief, selected: ImageStrategy, mode: string) {
  const avoid = brief.negative_prompt ? `Avoid: ${brief.negative_prompt}` : "";
  if (selected.textStrategy === "structured_overlay") return `${brief.media_prompt}\n\nGenerate a clean visual plate only. Leave intentional low-detail negative space for exact editorial overlays. Do not render text, letters, numbers, logos, watermarks, signs, screens, interface elements, captions, or CTA graphics anywhere in the image. ${avoid}`;
  const copy = selected.fieldOwnership.filter((field) => field.renderer === "model").map((field) => {
    const value = field.field === "headline" ? brief.text_overlay.headline.text : field.field === "subhead" ? brief.text_overlay.subhead.text : brief.text_overlay.cta.text;
    return `${field.field}: “${value}”`;
  }).join("; ");
  const regeneration = mode === "update_design"
    ? "Use the supplied previous artwork as a strong visual reference. Preserve its subject, palette, lighting, identity, and compositional character while redesigning the typography naturally around the approved copy."
    : mode === "reimagine" ? "Reimagine the composition substantially while preserving the approved message and brand constraints." : "Create a finished, art-directed social image.";
  const direction = selected.textStrategy === "ai_native" ? "Typography must be a central creative element integrated into the visual idea." : "Create premium product-led artwork with expressive typography integrated into the scene.";
  return `${brief.media_prompt}\n\n${regeneration} ${direction}\nRender only this exact model-owned copy with correct spelling and punctuation: ${copy}. Do not render the CTA, brand logo, URLs, prices, statistics, disclaimers, or any other words; Rithena adds exact fields afterward. Reserve a calm lower safe area for the exact CTA and a clear upper corner for the exact logo. ${avoid}`;
}

export function imageComposition(brand: Record<string, unknown>, brief: CreativeBrief, sourceAssetId: string, selected: ImageStrategy) {
  const layout = brief.text_overlay.layout; const left = layout === "left_stacked"; const structured = selected.textStrategy === "structured_overlay";
  const layers: Record<string, unknown>[] = [{ id: "plate", kind: "source_image", name: "Generated artwork", visible: true, order: 1, bounds: { x: 0, y: 0, width: 1, height: 1 }, assetId: sourceAssetId, focalPoint: { x: left ? 0.68 : 0.5, y: 0.5 }, fit: "cover" }];
  if (structured) {
    layers.push(
      { id: "contrast", kind: "treatment", name: "Text contrast", visible: true, order: 2, bounds: left ? { x: 0, y: 0, width: 0.62, height: 1 } : { x: 0, y: 0.55, width: 1, height: 0.45 }, treatment: layout === "centered_serif" ? "scrim" : "gradient", styleToken: "brand.contrast" },
      { id: "title", kind: "text", name: "Title", visible: true, order: 3, bounds: left ? { x: 0.08, y: 0.2, width: 0.48, height: 0.25 } : { x: 0.08, y: 0.58, width: 0.84, height: 0.16 }, role: "title", text: brief.text_overlay.headline.text, styleToken: layout === "centered_serif" ? "type.display-serif" : "type.display-bold", alignment: left ? "left" : "center" },
      { id: "subtitle", kind: "text", name: "Subtitle", visible: Boolean(brief.text_overlay.subhead.text), order: 4, bounds: left ? { x: 0.08, y: 0.49, width: 0.48, height: 0.12 } : { x: 0.12, y: 0.74, width: 0.76, height: 0.08 }, role: "subtitle", text: brief.text_overlay.subhead.text || " ", styleToken: "type.body", alignment: left ? "left" : "center" },
    );
  } else layers.push({ id: "cta-contrast", kind: "treatment", name: "CTA contrast", visible: true, order: 4, bounds: { x: 0, y: 0.82, width: 1, height: 0.1 }, treatment: "scrim", styleToken: "brand.contrast" });
  layers.push({ id: "cta", kind: "text", name: "Call to action", visible: true, order: 5, bounds: structured && left ? { x: 0.08, y: 0.78, width: 0.48, height: 0.07 } : { x: 0.12, y: 0.84, width: 0.76, height: 0.06 }, role: "cta", text: brief.text_overlay.cta.text, styleToken: "type.cta", alignment: structured && left ? "left" : "center" });
  const visual = (brand.visual || {}) as Record<string, unknown>;
  if (typeof visual.logoUrl === "string" && visual.logoUrl.startsWith("https://")) layers.push({ id: "logo", kind: "logo", name: "Exact brand logo", visible: true, order: 6, bounds: { x: 0.08, y: 0.07, width: 0.16, height: 0.08 }, assetId: "brand-logo", placement: "top_left" });
  return { schemaVersion: 1, format: "image", canvas: { width: 1080, height: 1350, aspectRatio: "4:5" }, safeZones: [{ id: "content-safe", purpose: "content", x: 0.06, y: 0.06, width: 0.88, height: 0.84 }, { id: "platform-ui", purpose: "platform_ui", x: 0, y: 0.92, width: 1, height: 0.08 }], layers, brandStyleId: `${String(brand.name || "brand").toLowerCase().replace(/[^a-z0-9]+/g, "-") || "brand"}-v1` };
}

