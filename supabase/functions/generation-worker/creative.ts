export type CreativeBrief = {
  media_prompt: string;
  negative_prompt: string;
  text_overlay: {
    layout: "bottom_minimal" | "centered_serif" | "left_stacked";
    headline: { text: string; in_time: number; out_time: number };
    subhead: { text: string; in_time: number; out_time: number };
    cta: { text: string; in_time: number; out_time: number };
  };
  audio_cue: string;
  carousel_slides?: Array<{ headline: string; body: string; media_prompt: string }>;
  social_post: {
    caption: string;
    hashtags: Record<string, string[]>;
    titles: { youtube: string; tiktok: string };
  };
};

type BriefJob = { type: "image" | "video"; input: Record<string, unknown> };

export function creativeBriefPrompt(job: BriefJob) {
  const input = job.input || {};
  const strategy = input.strategy || {};
  const brandBrain = input.brandBrain || {};
  const brain = brandBrain as Record<string, unknown>;
  const visual = brain.visual && typeof brain.visual === "object" ? brain.visual as Record<string, unknown> : {};
  const styleContract = {
    creativePersonalities: brain.personalities || [],
    colors: visual.colors || [],
    typographyClues: visual.typographyClues || [],
    photographyStyle: visual.photographyStyle || [],
    visualKeywords: visual.visualKeywords || [],
    bannedTreatments: visual.bannedTreatments || [],
  };
  const regenerationDirection = typeof input.regenerationDirection === "string" ? input.regenerationDirection.trim() : "";
  const regenerationKind = input.regenerationKind === "modify" ? "modify" : "new";
  const contentFormat = String((input as Record<string, unknown>).contentFormat || "");
  const carousel = contentFormat === "carousel";
  const medium = job.type === "video" ? "one continuous 8-second vertical 9:16 video" : carousel ? "a coherent four-slide 1080x1350 social carousel" : "one 1080x1350 4:5 portrait image";
  return `You are a senior commercial producer, art director, and social copywriter. Create a production-ready brief for ${medium}.

BRAND BRAIN (the only source of business truth):
${JSON.stringify(brandBrain, null, 2)}

PLANNED CONTENT:
${JSON.stringify(strategy, null, 2)}

MANDATORY VISUAL STYLE CONTRACT:
${JSON.stringify(styleContract, null, 2)}
- Translate every selected creative personality, photography style, visual keyword, and palette color into concrete decisions in media_prompt.
- State where the selected colors appear and express the personalities through composition, lighting, camera behavior, texture, styling, and pace.
- Use typography clues for the separate deterministic overlay plan; for video, never ask Veo to draw that typography.
- Every banned treatment is a hard exclusion and must also appear in negative_prompt.
- These are requirements, not optional inspiration. Do not replace them with generic stock photography, a generic SaaS aesthetic, or an unrelated cinematic treatment.

${regenerationDirection ? `REGENERATION DIRECTION
${regenerationKind === "modify" ? "The current creative will be supplied to the image model as a visual reference. Apply only the requested changes and preserve its recognizable subject, composition, camera angle, and visual identity wherever the direction does not require a change." : "Create a fresh rendition of the same planned idea without copying the previous composition."} Follow this human direction while preserving verified brand facts, the planned CTA, and platform constraints:
${regenerationDirection}
` : ""}

GROUNDING RULES
- Work for the supplied brand in any industry. Never import another company, product, audience, feature, location, URL, or visual identity.
- Every claim must be supported by the Brand Brain. Never invent statistics, pricing, customers, awards, results, or product functionality.
- Convert the planned concept into one concrete, specific visual. Describe subject, setting, materials, lighting direction, camera angle, color palette, texture, depth, mood, and composition.
- Follow the supplied visual identity, photography style, colors, personality, banned treatments, voice examples, and banned phrases.
- Avoid generic stock imagery, generic AI swirls, glossy purple SaaS gradients, split panels, collages, fake screenshots, distorted anatomy, warped architecture, watermarks, and unrelated props.

${job.type === "video" ? `VIDEO DIRECTION
- Write the media_prompt like a film director briefing a cinematographer for one hero shot. Specify, in order: shot type, one camera move, one hero subject, one simple physical action, setting, lighting direction, material texture, restrained palette, depth of field, and emotional mood.
- Use one continuous shot and one controlled camera move across all 8 seconds: slow push-in, tripod-smooth lateral drift, slow pan, or subtle parallax. Never imply a montage, transition, second angle, or cut.
- Keep the scene physically simple: one focal subject, one action, few background objects, stable geometry, natural motion, and uncluttered negative space reserved for deterministic overlays.
- Use observed, brand-relevant environments rather than generic stock staging. Prefer atmospheric directional light, intentional warm/cool contrast, tactile materials, realistic reflections, and slightly restrained commercial color.
- The footage is a clean visual plate. Do not show or describe screens, phones, tablets, monitors, dashboards, interfaces, documents, forms, books, newspapers, mail, signs, labels, packaging, license plates, clothing graphics, logos, watermarks, symbols, letters, numbers, or any surface that invites generated writing. Replace such props with textless physical metaphors and unmarked surfaces.
- Do not mention headline, subhead, CTA, typography, copy, caption, text placement, or brand mark inside media_prompt. All words and branding are composited later with FFmpeg.
- No dialogue, narrator, lip-sync, generated music, or generated audio. If a person is essential, keep the action natural and hands anatomically simple; otherwise prefer a cinematic environment or object-led shot.
- End the media_prompt with this exact sentence: Vertical 9:16 framing, 8 seconds, 1080p, photorealistic cinematic video quality, shallow depth of field, stable geometry, tripod-smooth continuous motion, clean unmarked surfaces, silent video with no audio, no text or writing of any kind anywhere in frame.
- negative_prompt must begin with the complete text-suppression list: text, words, letters, numbers, typography, subtitles, subtitle overlay, subtitle track, captions, closed captions, burned-in captions, caption bar, karaoke text, animated text, on-screen writing, text overlay, lower third, speech bubble, transcription, watermark, logo, brand mark, readable signage, labels, packaging text, document text, book text, newspaper text, license plate text, clothing graphics, visible screens, phones, tablets, monitors, app UI, dashboard, interface. Then add shot-specific exclusions such as jump cuts, camera shake, warped geometry, flicker, morphing objects, extra fingers, distorted hands, harsh flat lighting, oversaturated colors, and generic stock-footage aesthetics.
` : carousel ? `CAROUSEL DIRECTION
- Return exactly four carousel_slides. Slide 1 is a strong cover; slides 2 and 3 develop the useful idea; slide 4 concludes with the CTA.
- Every slide needs a distinct composition and purpose while sharing the same subject world, palette, lighting, typography, and visual identity.
- Each slide headline is 2-6 words and each body is at most 16 words. Do not repeat the same wording or visual on multiple slides.
- Each media_prompt must fully describe that slide and instruct the image model to render only its exact headline and body with correct spelling.
- Use the whole 4:5 canvas with mobile-safe margins. Keep all text at least 8% from every edge.
` : `IMAGE DIRECTION
- Use the whole 4:5 canvas as one seamless composition with deliberate negative space and mobile-safe margins.
- Render the exact headline, subhead, and CTA from text_overlay as clean, correctly spelled, high-contrast editorial typography integrated into the scene. Do not render any other words.
- Keep all text at least 8% from every edge. Headline belongs in the upper third, hero visual in the center, CTA in the lower safe area.
- Use a credible premium type style consistent with the supplied Brand Brain. No pill-shaped CTA buttons.
`}
TEXT OVERLAY
- A sound-off viewer must understand the message. Headline: 3-6 words. Subhead: at most 14 words. CTA: at most 5 words. Total at most 25 words.
- Use specific benefit language supported by the Brand Brain. Do not copy the plan verbatim when a sharper line is possible.
- For video, headline begins by 0.6s, subhead after 2s, CTA during the final 2 seconds. No overlap that harms reading.
- Choose bottom_minimal by default, centered_serif for emotional brand-led work, or left_stacked only when the shot deliberately leaves space on the left.

SOCIAL COPY
- Write like a thoughtful human operator. Be concrete, conversational, confident, and restrained.
- Caption: 3-5 short sentences. Open with the audience's real problem or desire, connect it to the supported benefit, mention the brand naturally, and close with the CTA.
- Return platform-specific hashtags: exactly 10 each for Instagram, TikTok, and YouTube; exactly 5 for LinkedIn. Do not duplicate the same set across platforms.
- YouTube title: useful and searchable, at most 60 characters. TikTok title: conversational, at most 80 characters.
- Audio cue format: Mood: [descriptor] — Genre: [instrumental genre] — Tempo: [BPM range], no lyrics.

Return only valid JSON with this exact shape:
{
  "media_prompt": "detailed generation prompt of at least 140 words",
  "negative_prompt": "comma-separated exclusions",
  "text_overlay": {
    "layout": "bottom_minimal",
    "headline": { "text": "", "in_time": 0.5, "out_time": 5.5 },
    "subhead": { "text": "", "in_time": 2.2, "out_time": 6.5 },
    "cta": { "text": "", "in_time": 6, "out_time": 8 }
  },
  "audio_cue": "",
  "carousel_slides": ${carousel ? `[
    { "headline": "", "body": "", "media_prompt": "" },
    { "headline": "", "body": "", "media_prompt": "" },
    { "headline": "", "body": "", "media_prompt": "" },
    { "headline": "", "body": "", "media_prompt": "" }
  ]` : "[]"},
  "social_post": {
    "caption": "",
    "hashtags": { "instagram": [], "facebook": [], "linkedin": [], "tiktok": [], "youtube": [] },
    "titles": { "youtube": "", "tiktok": "" }
  }
}`;
}

export function parseCreativeBrief(text: string): CreativeBrief {
  const cleaned = text.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  const start = cleaned.indexOf("{"); const end = cleaned.lastIndexOf("}");
  if (start < 0 || end <= start) throw new Error("Creative director returned no JSON object");
  const value = JSON.parse(cleaned.slice(start, end + 1)) as CreativeBrief;
  if (!value.media_prompt || !value.text_overlay?.headline?.text || !value.social_post?.caption) throw new Error("Creative director returned an incomplete brief");
  return value;
}
