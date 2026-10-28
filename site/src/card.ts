// A shared stop's card as a PNG, for link previews in apps that fetch them from the page (WhatsApp,
// Signal, Slack…; Messages gets the app's own card). Like the app's ShareCard: the ride, the wait, a
// quip and where it came from, drawn as SVG and turned into a PNG by resvg, with Nunito standing in
// for SF Rounded.

import { initWasm, Resvg } from "@resvg/resvg-wasm";
// @ts-ignore: wrangler hands these over as a compiled module and as bytes.
import resvgWasm from "@resvg/resvg-wasm/index_bg.wasm";
// @ts-ignore
import black from "./fonts/Nunito-Black.ttf";
// @ts-ignore
import semibold from "./fonts/Nunito-SemiBold.ttf";

const WIDTH = 1200;
const HEIGHT = 630;

let ready: Promise<void> | undefined;

export interface Card {
  /** "37", "KLM": as on the app's badges. */
  badge: string;
  destination: string;
  stop: string;
  /** Minutes until the next few, the first one big; empty when none is coming. */
  minutes: number[];
  live: boolean;
  /** Which line each of `minutes` is, for combined lines. */
  lines?: string[];
  quip: string;
}

export async function renderCard(card: Card): Promise<Uint8Array> {
  ready ??= initWasm(resvgWasm as WebAssembly.Module);
  await ready;
  const resvg = new Resvg(svg(card), {
    font: { fontBuffers: [new Uint8Array(black), new Uint8Array(semibold)], defaultFontFamily: "Nunito", loadSystemFonts: false },
    fitTo: { mode: "width", value: WIDTH },
  });
  return resvg.render().asPng();
}

function svg(card: Card): string {
  const red = "#bf1a26";
  const muted = "rgba(255,255,255,0.6)";
  const badgeSize = 64;
  const badgeWidth = Math.round(textWidth(card.badge, badgeSize, true) + 40);
  const left = 72;
  const textLeft = left + badgeWidth + 28;
  const room = WIDTH - textLeft - 72;
  const [first, ...later] = card.minutes;
  const wait = first === undefined ? "??" : first === 0 ? "now" : String(first);
  const then = later.slice(0, 2).map((m, i) => (card.lines ? `${card.lines[i + 1]} ` : "") + m).join(" · ");
  const thenLine = [card.lines && first !== undefined ? `the ${card.lines[0]}` : "", then ? `then ${then} min` : ""].filter(Boolean).join(", ");
  const waitSize = 190;
  const quip = fit(`“${card.quip}”`, 40, WIDTH - left * 2, false);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${WIDTH}" height="${HEIGHT}" viewBox="0 0 ${WIDTH} ${HEIGHT}">
  <defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#141729"/><stop offset="1" stop-color="#33142a"/></linearGradient></defs>
  <rect width="${WIDTH}" height="${HEIGHT}" fill="url(#bg)"/>
  <rect x="${left}" y="64" width="${badgeWidth}" height="92" rx="14" fill="${red}"/>
  <text x="${left + badgeWidth / 2}" y="133" font-size="${badgeSize}" font-weight="900" fill="#fff" text-anchor="middle">${escape(card.badge)}</text>
  <text x="${textLeft}" y="104" font-size="44" font-weight="900" fill="#fff">${escape(fit(`To ${card.destination}`, 44, room, true))}</text>
  <text x="${textLeft}" y="150" font-size="32" font-weight="600" fill="${muted}">${escape(fit(card.stop, 32, room, false))}</text>
  <text x="${left}" y="${330 + 50}" font-size="${waitSize}" font-weight="900" fill="${card.live && first !== undefined ? "#4cd964" : muted}">${escape(wait)}${first ? `<tspan font-size="64" dx="18">min</tspan>` : ""}</text>
  ${thenLine ? `<text x="${left}" y="440" font-size="36" font-weight="600" fill="${muted}">${escape(fit(thenLine, 36, WIDTH - left * 2, false))}</text>` : ""}
  <text x="${left}" y="508" font-size="40" font-weight="600" fill="#fff">${escape(quip)}</text>
  <rect x="${left}" y="${HEIGHT - 88}" width="58" height="40" rx="8" fill="${red}"/>
  <text x="${left + 29}" y="${HEIGHT - 57}" font-size="26" font-weight="900" fill="#fff" text-anchor="middle">37</text>
  <text x="${left + 74}" y="${HEIGHT - 56}" font-size="30" font-weight="900" fill="#fff">37 Shades of Late</text>
  <text x="${left + 360}" y="${HEIGHT - 56}" font-size="26" font-weight="600" fill="${muted}">37shadesoflate.com</text>
</svg>`;
}

/** Roughly how wide Nunito sets `text` at `size`; there's no measuring before resvg draws it. */
function textWidth(text: string, size: number, heavy: boolean): number {
  let em = 0;
  for (const c of text) em += /[il.,·:;'’!|]/.test(c) ? 0.28 : /[mwMW]/.test(c) ? 0.86 : /[A-Z0-9]/.test(c) ? 0.66 : c === " " ? 0.26 : 0.56;
  return em * size * (heavy ? 0.96 : 1);
}

/** `text`, cut short with an ellipsis to fit `width`. */
function fit(text: string, size: number, width: number, heavy: boolean): string {
  if (textWidth(text, size, heavy) <= width) return text;
  let cut = text;
  while (cut.length > 1 && textWidth(cut + "…", size, heavy) > width) cut = cut.slice(0, -1);
  return cut.trimEnd() + "…";
}

function escape(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
