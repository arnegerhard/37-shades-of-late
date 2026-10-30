// Draws images/preview.png, the homepage's link preview (what Messages, Slack and friends show for
// 37shadesoflate.com): the name in the app icon's red box, a line about it, and the map of the cities
// from images/cities.svg with every city on it. Without it, previews pick the biggest picture on the page,
// the live 37's share card, and every link to the site looks like a shared stop. build.sh copies it in;
// run this again after cities.mjs:
//
//     node site/scripts/preview.mjs

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { initWasm, Resvg } from "../node_modules/@resvg/resvg-wasm/index.mjs";

const site = join(dirname(fileURLToPath(import.meta.url)), "..");
const W = 1200, H = 630;

// The map as the page shows it once the story is done: the country, every city's card on.
const map = readFileSync(join(site, "images", "cities.svg"), "utf8")
  .replace(/^<svg[^>]*>/, "").replace(/<\/svg>\s*$/, "")
  .replace(/<g class="sf">.*?<\/g>/s, "").replace(/<g class="the37">.*?<\/g>/s, "")
  .replace(/<circle class="ping"[^>]*\/>/g, "");
const style = `
  .land { fill: #161933; stroke: #2e3463; stroke-width: 1.5; stroke-linejoin: round; }
  .borders { fill: none; stroke: #252a4f; stroke-width: .8; }
  .leader { fill: none; stroke: #ffffff59; stroke-width: 1.5; }
  .spot { fill: #ff3b4a; }
  .card rect { fill: #12142a; stroke: #2a2f55; stroke-width: 2; }
  .lines { fill: none; stroke-width: 3.5; stroke-linecap: round; stroke-linejoin: round; }
  .name { font-size: 23px; font-weight: 900; fill: #f4f1ea; text-anchor: middle; }
  .who { font-size: 15px; font-weight: 600; fill: #a8a6b3; text-anchor: middle; }`;

const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
<style>${style}</style>
<rect width="${W}" height="${H}" fill="#0b0d17"/>
<rect x="64" y="92" width="118" height="92" rx="18" fill="#bf1a26"/>
<text x="123" y="166" font-size="76" font-weight="900" fill="#fff" text-anchor="middle">37</text>
<text x="64" y="268" font-size="72" font-weight="900" fill="#f4f1ea">Shades of Late</text>
<text x="66" y="340" font-size="31" font-weight="600" fill="#a8a6b3">Minutes until your bus or train,</text>
<text x="66" y="382" font-size="31" font-weight="600" fill="#a8a6b3">right on your Lock Screen.</text>
<text x="66" y="470" font-size="31" font-weight="900" fill="#ff3b4a">Seven cities. Same feeling.</text>
<svg x="590" y="20" width="590" height="590" viewBox="0 0 1000 980">${map}</svg>
</svg>`;

await initWasm(readFileSync(join(site, "node_modules", "@resvg", "resvg-wasm", "index_bg.wasm")));
const fonts = ["Nunito-Black.ttf", "Nunito-SemiBold.ttf"].map((f) => new Uint8Array(readFileSync(join(site, "src", "fonts", f))));
const png = new Resvg(svg, { font: { fontBuffers: fonts, defaultFontFamily: "Nunito", loadSystemFonts: false } }).render().asPng();
writeFileSync(join(site, "images", "preview.png"), png);
console.log(`images/preview.png: ${Math.round(png.length / 1024)} KB`);
