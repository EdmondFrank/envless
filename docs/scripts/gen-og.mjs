// Generates docs/public/og-image.png (1200x630) from an inline SVG.
// Run: node scripts/gen-og.mjs
import sharp from "sharp";
import { writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const svg = `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 630" width="1200" height="630">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#0e0a07"/>
      <stop offset="100%" stop-color="#1d130c"/>
    </linearGradient>
    <linearGradient id="accent" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0%" stop-color="#d96e3a"/>
      <stop offset="100%" stop-color="#f2a07a"/>
    </linearGradient>
  </defs>
  <rect width="1200" height="630" fill="url(#bg)"/>
  <g transform="translate(80,90)">
    <rect x="0" y="0" width="120" height="120" rx="22" fill="#17110d" stroke="#d96e3a" stroke-width="2"/>
    <path d="M25 28h70v14H42v15h33v13H42v18h53v14H25V28Z" fill="url(#accent)"/>
    <circle cx="100" cy="29" r="9" fill="#d96e3a"/>
  </g>
  <text x="80" y="370" font-family="ui-sans-serif, system-ui, -apple-system, 'Segoe UI', sans-serif" font-size="120" font-weight="800" fill="#f3ebe4">envless</text>
  <text x="80" y="440" font-family="ui-sans-serif, system-ui, -apple-system, 'Segoe UI', sans-serif" font-size="36" font-weight="500" fill="#d96e3a">agent-first secrets</text>
  <text x="80" y="490" font-family="ui-monospace, 'SF Mono', Menlo, monospace" font-size="26" font-weight="400" fill="#a89488">zero .env  ·  zero servers  ·  process.env kept</text>
  <g transform="translate(80,550)">
    <rect x="0" y="0" width="14" height="14" fill="#d96e3a"/>
    <text x="26" y="13" font-family="ui-monospace, 'SF Mono', Menlo, monospace" font-size="20" fill="#a89488">github.com/biliboss/envless</text>
  </g>
  <g transform="translate(1050,40)" opacity="0.8">
    <rect width="80" height="30" rx="4" fill="#2a1a14" stroke="#d96e3a" stroke-width="1"/>
    <text x="40" y="20" text-anchor="middle" font-family="ui-monospace, monospace" font-size="14" fill="#d96e3a">v0.0.1</text>
  </g>
</svg>`;

const out = resolve(__dirname, "..", "public", "og-image.png");
await sharp(Buffer.from(svg)).resize(1200, 630).png().toFile(out);
console.log("wrote", out);
