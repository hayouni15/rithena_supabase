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
  const medium = job.type === "video" ? "one continuous 8-second vertical 9:16 video" : "one 1080x1350 4:5 portrait image";
  return `You are a senior commercial producer, art director, and social copywriter. Create a production-ready brief for ${medium}.

BRAND BRAIN (the only source of business truth):
${JSON.stringify(brandBrain, null, 2)}

PLANNED CONTENT:
${JSON.stringify(strategy, null, 2)}

GROUNDING RULES
- Work for the supplied brand in any industry. Never import another company, product, audience, feature, location, URL, or visual identity.
- Every claim must be supported by the Brand Brain. Never invent statistics, pricing, customers, awards, results, or product functionality.
- Convert the planned concept into one concrete, specific visual. Describe subject, setting, materials, lighting direction, camera angle, color palette, texture, depth, mood, and composition.
- Follow the supplied visual identity, photography style, colors, personality, banned treatments, voice examples, and banned phrases.
- Avoid generic stock imagery, generic AI swirls, glossy purple SaaS gradients, split panels, collages, fake screenshots, distorted anatomy, warped architecture, watermarks, and unrelated props.

${job.type === "video" ? `VIDEO DIRECTION
- One shot and one controlled camera move across all 8 seconds. Prefer a slow push-in, gentle lateral drift, slow pan, or subtle parallax.
- The subject performs one physically plausible action. Keep the number of people, objects, and simultaneous movements low to reduce visual hallucination.
- Use photorealistic cinematic lighting and stable geometry. No cuts, scene changes, dialogue, narrator, lip movement, or generated audio.
- The media_prompt must not ask Veo to render text, logos, signs, screens, UI, subtitles, captions, or writing. All words are added later.
- End the media_prompt with: Vertical 9:16 framing, 8 seconds, photorealistic cinematic quality, shallow depth of field, stable geometry, no camera shake, smooth continuous motion, silent video with no audio, no text or writing of any kind in frame.
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
