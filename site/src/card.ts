// A shared stop's card as a PNG, for link previews in apps that fetch them from the page (WhatsApp,
// Signal, Slack…; Messages gets the app's own card). Like the app's ShareCard: the ride, the wait, a
// quip and where it came from, drawn as SVG and turned into a PNG by resvg, with Nunito standing in
// for SF Rounded. With a map (an Apple Maps snapshot, see mapkit.ts), the right half shows the route,
// the stop and the buses on their way, as the app's live map does, and the text moves to the left.

import { initWasm, Resvg } from "@resvg/resvg-wasm";
// @ts-ignore: wrangler hands these over as a compiled module and as bytes.
import resvgWasm from "@resvg/resvg-wasm/index_bg.wasm";
// @ts-ignore
import black from "./fonts/Nunito-Black.ttf";
// @ts-ignore
import semibold from "./fonts/Nunito-SemiBold.ttf";

const WIDTH = 1200;
const HEIGHT = 630;
/** The PNG's width; drawn at WIDTH × HEIGHT and scaled. */
export const OUTPUT_WIDTH = 800;

let ready: Promise<void> | undefined;

export interface Card {
  /** "37", "KLM": as on the app's badges. */
  badge: string;
  /** A round badge, as New York's subway and Muni Metro have (see `isRound` in worker.ts). */
  round?: boolean;
  /** The badges, in their colors (see `badgeParts` in worker.ts); `badge` in red without them. */
  parts?: BadgePart[];
  destination: string;
  stop: string;
  /** Minutes until the next few, the first one big; empty when none is coming. */
  minutes: number[];
  live: boolean;
  /** Which line each of `minutes` is, for combined lines. */
  lines?: string[];
  quip: string;
  map?: CardMap;
}

/** The map half: its picture (MAP_WIDTH × HEIGHT) and what goes on it, in its points. */
export interface CardMap {
  png: Uint8Array;
  route: { x: number; y: number }[][];
  stop: { x: number; y: number };
  buses: { x: number; y: number; label: string; live: boolean }[];
}

export const MAP_WIDTH = 600;

/** One badge: some of the lines, in their color ("#RRGGBB", the app's red without one). */
export interface BadgePart {
  label: string;
  color?: string;
  /** Black letters, on New York's yellow. */
  dark?: boolean;
}

/** The card's badges side by side from `x`, `height` tall with letters `size` big, in at most
 * `room` (the last cut short to fit): their SVG, and how wide they came out. */
function badges(card: Card, x: number, y: number, height: number, size: number, room: number): { svg: string; width: number } {
  const parts = card.parts?.length ? card.parts : [{ label: card.badge }];
  const gap = Math.round(height / 9);
  let at = x;
  const svg = parts.map((part) => {
    const left = room - (at - x);
    if (left < height) return "";
    const label = fit(part.label, size, left - height * 0.45, true);
    const width = Math.min(left, Math.max(card.round ? height : 0, Math.round(textWidth(label, size, true) + height * (card.round ? 0.37 : 0.47))));
    const drawn = `<rect x="${at}" y="${y}" width="${width}" height="${height}" rx="${card.round ? height / 2 : height * 0.16}" fill="${part.color ?? red}"/>
  <text x="${at + width / 2}" y="${y + height * 0.75}" font-size="${size}" font-weight="900" fill="${part.dark ? "#000" : "#fff"}" text-anchor="middle">${escape(label)}</text>`;
    at += width + gap;
    return drawn;
  }).join("\n  ");
  return { svg, width: at - gap - x };
}

export async function renderCard(card: Card): Promise<Uint8Array> {
  ready ??= initWasm(resvgWasm as WebAssembly.Module);
  await ready;
  const resvg = new Resvg(svg(card), {
    font: { fontBuffers: [new Uint8Array(black), new Uint8Array(semibold)], defaultFontFamily: "Nunito", loadSystemFonts: false },
    // 800 wide rather than 1200: with a map, a full-size PNG gets past the 300 KB or so that some apps
    // (WhatsApp) take for a preview.
    fitTo: { mode: "width", value: OUTPUT_WIDTH },
  });
  return resvg.render().asPng();
}

function svg(card: Card): string {
  return card.map ? withMap(card, card.map) : textOnly(card);
}

const red = "#bf1a26";
const muted = "rgba(255,255,255,0.6)";
const background = `<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#141729"/><stop offset="1" stop-color="#33142a"/></linearGradient></defs>
  <rect width="${WIDTH}" height="${HEIGHT}" fill="url(#bg)"/>`;

/** What follows the first wait: "then 12 · 19 min", or "the K, then L 4 · M 9 min". */
function thenLine(card: Card): string {
  const [first, ...later] = card.minutes;
  const then = later.slice(0, 2).map((m, i) => (card.lines ? `${card.lines[i + 1]} ` : "") + m).join(" · ");
  return [card.lines && first !== undefined ? `the ${card.lines[0]}` : "", then ? `then ${then} min` : ""].filter(Boolean).join(", ");
}

function wait(card: Card, size: number, x: number, y: number): string {
  const first = card.minutes[0];
  const text = first === undefined ? "??" : first === 0 ? "now" : String(first);
  return `<text x="${x}" y="${y}" font-size="${size}" font-weight="900" fill="${card.live && first !== undefined ? "#4cd964" : muted}">${escape(text)}${first ? `<tspan font-size="${Math.round(size / 3)}" dx="${Math.round(size / 10)}">min</tspan>` : ""}</text>`;
}

function footer(x: number, y: number, size: number): string {
  return `<rect x="${x}" y="${y - size * 1.1}" width="${size * 2.2}" height="${size * 1.5}" rx="${size * 0.3}" fill="${red}"/>
  <text x="${x + size * 1.1}" y="${y}" font-size="${size}" font-weight="900" fill="#fff" text-anchor="middle">37</text>
  <text x="${x + size * 2.8}" y="${y}" font-size="${size * 1.15}" font-weight="900" fill="#fff">37 Shades of Late</text>`;
}

/** The text on the left, the map on the right. */
function withMap(card: Card, map: CardMap): string {
  const left = 64, width = WIDTH - MAP_WIDTH - left - 40, mapLeft = WIDTH - MAP_WIDTH;
  const badge = badges(card, left, 56, 76, 52, width);
  const thenText = thenLine(card);
  const quip = wrap(`“${card.quip}”`, 30, width, 2);
  const at = (p: { x: number; y: number }) => `${(mapLeft + p.x).toFixed(1)},${p.y.toFixed(1)}`;
  const route = map.route.filter((line) => line.length > 1)
    .map((line) => `<polyline points="${line.map(at).join(" ")}" fill="none" stroke="${red}" stroke-width="7" stroke-linecap="round" stroke-linejoin="round"/>`).join("\n    ");
  const buses = map.buses.map((bus) => `<circle cx="${mapLeft + bus.x}" cy="${bus.y}" r="27" fill="#1c1c1e" stroke="${red}" stroke-width="4"/>
    <text x="${mapLeft + bus.x}" y="${bus.y + (bus.label.length > 2 ? 7 : 9)}" font-size="${bus.label.length > 2 ? 18 : 25}" font-weight="900" fill="${bus.live ? "#4cd964" : "#fff"}" text-anchor="middle">${escape(bus.label)}</text>`).join("\n    ");
  return `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${WIDTH}" height="${HEIGHT}" viewBox="0 0 ${WIDTH} ${HEIGHT}">
  ${background}
  <clipPath id="map"><rect x="${mapLeft}" y="0" width="${MAP_WIDTH}" height="${HEIGHT}"/></clipPath>
  <g clip-path="url(#map)">
    <image x="${mapLeft}" y="0" width="${MAP_WIDTH}" height="${HEIGHT}" xlink:href="data:image/png;base64,${base64(map.png)}"/>
    ${route}
    <circle cx="${mapLeft + map.stop.x}" cy="${map.stop.y}" r="15" fill="#0a84ff" stroke="#fff" stroke-width="4"/>
    ${buses}
  </g>
  ${badge.svg}
  <text x="${left}" y="192" font-size="38" font-weight="900" fill="#fff">${escape(fit(`To ${card.destination}`, 38, width, true))}</text>
  <text x="${left}" y="234" font-size="28" font-weight="600" fill="${muted}">${escape(fit(card.stop, 28, width, false))}</text>
  ${wait(card, 150, left - 4, 392)}
  ${thenText ? `<text x="${left}" y="442" font-size="28" font-weight="600" fill="${muted}">${escape(fit(thenText, 28, width, false))}</text>` : ""}
  ${quip.map((line, i) => `<text x="${left}" y="${494 + i * 36}" font-size="30" font-weight="600" fill="#fff">${escape(line)}</text>`).join("\n  ")}
  ${footer(left, 604, 20)}
</svg>`;
}

/** Without a map: the text across the whole card. */
function textOnly(card: Card): string {
  const left = 72;
  const badge = badges(card, left, 64, 92, 64, 520);
  const textLeft = left + badge.width + 28;
  const room = WIDTH - textLeft - 72;
  const thenText = thenLine(card);
  const quip = fit(`“${card.quip}”`, 40, WIDTH - left * 2, false);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${WIDTH}" height="${HEIGHT}" viewBox="0 0 ${WIDTH} ${HEIGHT}">
  ${background}
  ${badge.svg}
  <text x="${textLeft}" y="104" font-size="44" font-weight="900" fill="#fff">${escape(fit(`To ${card.destination}`, 44, room, true))}</text>
  <text x="${textLeft}" y="150" font-size="32" font-weight="600" fill="${muted}">${escape(fit(card.stop, 32, room, false))}</text>
  ${wait(card, 190, left, 380)}
  ${thenText ? `<text x="${left}" y="440" font-size="36" font-weight="600" fill="${muted}">${escape(fit(thenText, 36, WIDTH - left * 2, false))}</text>` : ""}
  <text x="${left}" y="508" font-size="40" font-weight="600" fill="#fff">${escape(quip)}</text>
  ${footer(left, HEIGHT - 56, 26)}
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

/** `text` in up to `most` lines that fit `width`, the last one cut short if need be. */
function wrap(text: string, size: number, width: number, most: number): string[] {
  const lines: string[] = [];
  for (const word of text.split(" ")) {
    const last = lines[lines.length - 1];
    if (last !== undefined && textWidth(`${last} ${word}`, size, false) <= width) lines[lines.length - 1] = `${last} ${word}`;
    else lines.push(word);
  }
  return lines.length <= most ? lines : [...lines.slice(0, most - 1), fit(lines.slice(most - 1).join(" "), size, width, false)];
}

function base64(bytes: Uint8Array): string {
  let text = "";
  for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(text);
}

function escape(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
