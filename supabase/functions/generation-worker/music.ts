import type { CreativeBrief } from "./creative.ts";

const TRACKS = [
  "mixkit-a-baby-story-530.mp3", "mixkit-a-very-happy-christmas-897.mp3", "mixkit-classical-vibes-3-683 (1).mp3",
  "mixkit-classical-vibes-3-683.mp3", "mixkit-cyberpunk-city-140.mp3", "mixkit-fifth-of-february-1028.mp3",
  "mixkit-forest-treasure-138.mp3", "mixkit-forever-love-38.mp3", "mixkit-holiday-fun-87.mp3",
  "mixkit-i-believe-in-us-1030.mp3", "mixkit-just-keep-walking-963.mp3", "mixkit-piano-reflections-22.mp3",
  "mixkit-placeit-world-01-724.mp3", "mixkit-relax-beat-292.mp3", "mixkit-relaxation-05-749.mp3",
  "mixkit-serene-view-443.mp3", "mixkit-slow-pop-351.mp3", "mixkit-spirit-in-the-woods-139.mp3",
  "mixkit-summer-fun-13.mp3", "mixkit-tapis-615.mp3", "mixkit-trap-hamza-267.mp3",
  "mixkit-walking-in-the-park-529.mp3", "mixkit-wedding-music-272.mp3", "mixkit-you-and-me-1124.mp3",
] as const;

const moodTracks: Array<[RegExp, number[]]> = [
  [/calm|serene|reflect|gentle|reassur|relax/i, [11, 14, 15, 16]],
  [/warm|love|emotional|tender|family/i, [0, 6, 7, 23]],
  [/classical|elegant|sophisticat|premium/i, [2, 3, 5, 11]],
  [/upbeat|happy|bright|playful|summer/i, [1, 8, 18, 20]],
  [/urban|cyber|modern|energetic|bold/i, [4, 12, 19, 20]],
  [/nature|forest|organic|outdoor/i, [6, 17, 21]],
];

export function selectMusic(brief: CreativeBrief, seed: string) {
  const candidates = moodTracks.find(([pattern]) => pattern.test(brief.audio_cue))?.[1] || TRACKS.map((_, index) => index);
  let hash = 0; for (const character of seed) hash = ((hash << 5) - hash + character.charCodeAt(0)) | 0;
  const file = TRACKS[candidates[Math.abs(hash) % candidates.length]];
  const base = Deno.env.get("MUSIC_LIBRARY_BASE_URL") || "https://objectstorage.ca-montreal-1.oraclecloud.com/n/axr2mzsugevy/b/rithena/o/music/";
  return `${base.replace(/\/?$/, "/")}${encodeURIComponent(file)}`;
}
