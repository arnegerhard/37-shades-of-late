/** A line on the map: [[lat, lon], ...]. */
export type Polyline = [number, number][];

/**
 * Douglas–Peucker simplification in meters, so whole-city route maps stay small to send.
 * A ~12 m tolerance keeps every corner a rider would recognize at city zoom.
 */
export function simplify(points: Polyline, toleranceMeters = 12): Polyline {
  if (points.length < 3) return points.map(round);
  const lat0 = points[0][0];
  const toMeters = (p: [number, number]) => [p[1] * 111_320 * Math.cos((lat0 * Math.PI) / 180), p[0] * 110_540];
  const projected = points.map(toMeters);
  const keep = new Uint8Array(points.length);
  keep[0] = keep[points.length - 1] = 1;
  const stack: [number, number][] = [[0, points.length - 1]];
  while (stack.length) {
    const [start, end] = stack.pop()!;
    const [ax, ay] = projected[start], [bx, by] = projected[end];
    const dx = bx - ax, dy = by - ay, length = Math.hypot(dx, dy) || 1;
    let farthest = -1, distance = toleranceMeters;
    for (let i = start + 1; i < end; i++) {
      const [px, py] = projected[i];
      const d = Math.abs(dy * px - dx * py + bx * ay - by * ax) / length;
      if (d > distance) { distance = d; farthest = i; }
    }
    if (farthest >= 0) {
      keep[farthest] = 1;
      stack.push([start, farthest], [farthest, end]);
    }
  }
  return points.filter((_, i) => keep[i]).map(round);
}

function round([lat, lon]: [number, number]): [number, number] {
  return [Math.round(lat * 1e5) / 1e5, Math.round(lon * 1e5) / 1e5];
}

/** Reads one file out of a ZIP archive (stored or deflated), e.g. routes.txt from a GTFS feed. */
export async function readZipEntry(zip: ArrayBuffer, name: string): Promise<string | undefined> {
  const view = new DataView(zip);
  // The end-of-central-directory record sits in the last 64 KB.
  let eocd = -1;
  for (let i = zip.byteLength - 22; i >= Math.max(0, zip.byteLength - 65_557); i--) {
    if (view.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) return undefined;
  let entry = view.getUint32(eocd + 16, true);
  const count = view.getUint16(eocd + 10, true);
  const decoder = new TextDecoder();
  for (let i = 0; i < count && view.getUint32(entry, true) === 0x02014b50; i++) {
    const method = view.getUint16(entry + 10, true);
    const size = view.getUint32(entry + 20, true);
    const nameLength = view.getUint16(entry + 28, true);
    const extraLength = view.getUint16(entry + 30, true);
    const commentLength = view.getUint16(entry + 32, true);
    const local = view.getUint32(entry + 42, true);
    const entryName = decoder.decode(new Uint8Array(zip, entry + 46, nameLength));
    if (entryName === name || entryName.endsWith(`/${name}`)) {
      const start = local + 30 + view.getUint16(local + 26, true) + view.getUint16(local + 28, true);
      const bytes = new Uint8Array(zip, start, size);
      if (method === 0) return decoder.decode(bytes);
      if (method !== 8) return undefined;
      const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
      return await new Response(stream).text();
    }
    entry += 46 + nameLength + extraLength + commentLength;
  }
  return undefined;
}

/** Parses CSV (with quoted fields) into objects keyed by the header row. */
export function parseCSV(text: string): Record<string, string>[] {
  const rows: string[][] = [];
  let row: string[] = [], field = "", quoted = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') { field += '"'; i++; }
      else if (c === '"') quoted = false;
      else field += c;
    } else if (c === '"') quoted = true;
    else if (c === ",") { row.push(field); field = ""; }
    else if (c === "\n" || c === "\r") {
      if (c === "\r" && text[i + 1] === "\n") i++;
      row.push(field); field = "";
      if (row.length > 1 || row[0]) rows.push(row);
      row = [];
    } else field += c;
  }
  if (field || row.length) { row.push(field); rows.push(row); }
  const [header = [], ...data] = rows;
  const keys = header.map((h) => h.replace(/^﻿/, "").trim());
  return data.map((r) => Object.fromEntries(keys.map((k, i) => [k, r[i] ?? ""])));
}

/** A GTFS color ("005B95") as "#005B95", or undefined if missing or malformed. */
export function hexColor(value: unknown): string | undefined {
  const hex = String(value ?? "").trim().replace(/^#/, "");
  return /^[0-9a-f]{6}$/i.test(hex) ? `#${hex.toUpperCase()}` : undefined;
}

/**
 * "K,L,M" + "IB" (or "IB,IB,OB") + "15728" (or a stop per line) → [{line: "K", direction: "IB", stop: "15728"}, ...].
 * A single direction or stop applies to every line.
 */
export function linePairs(lines: string, directions: string | null, stops: string): { line: string; direction?: string; stop: string }[] {
  const dirs = (directions ?? "").split(",");
  const stopList = stops.split(",");
  return lines.split(",").filter(Boolean).slice(0, 8)
    .map((line, i) => ({
      line,
      direction: (dirs.length > 1 ? dirs[i] : dirs[0]) || undefined,
      stop: (stopList.length > 1 ? stopList[i] : stopList[0]) ?? "",
    }));
}

/** How far "Also fine with" looks for other stops: a minute or two on foot. */
export const NEARBY_METERS = 150;

/** Meters between two points; flat-earth, plenty accurate across a few blocks. */
export function metersBetween(a: { lat: number; lon: number }, b: { lat: number; lon: number }): number {
  const x = (b.lon - a.lon) * 111_320 * Math.cos((a.lat * Math.PI) / 180);
  const y = (b.lat - a.lat) * 111_320;
  return Math.hypot(x, y);
}

export interface NearbyLine {
  line: string;
  direction: string;
  destination: string;
  /** Where to catch it; the picked stop itself, or one up to NEARBY_METERS away. */
  stop: string;
  stopName: string;
  distance: number;
  lat?: number;
  lon?: number;
}

/** One entry per line and direction, at the closest stop that has it, nearest first. */
export function closestPerLine(lines: NearbyLine[]): NearbyLine[] {
  const best = new Map<string, NearbyLine>();
  for (const l of lines) {
    const key = `${l.line}|${l.direction}`;
    const seen = best.get(key);
    if (l.line && (!seen || l.distance < seen.distance)) best.set(key, l);
  }
  return [...best.values()].sort((a, b) => a.distance - b.distance || a.line.localeCompare(b.line, "en", { numeric: true }));
}

/** Distinct line + direction pairs among a stop's upcoming visits, with a destination each. */
export function linesAtStop(visits: { line: string; direction: string; destination: string }[]) {
  const seen = new Map<string, { line: string; direction: string; destination: string }>();
  for (const v of visits) {
    const key = `${v.line}|${v.direction}`;
    if (v.line && !seen.has(key)) seen.set(key, { line: v.line, direction: v.direction, destination: v.destination });
  }
  return [...seen.values()].sort((a, b) => a.line.localeCompare(b.line, "en", { numeric: true }));
}

/**
 * A line's shapes made fit to draw on a map of every line: shapes that only retrace others (the
 * second direction, short turns) dropped, and pieces that meet end to end joined into one. Fewer,
 * longer lines are what keeps MapKit smooth with a city's worth of them.
 */
export function mergeShapes(shapes: Polyline[], toleranceMeters = 40): Polyline[] {
  const kept: Polyline[] = [];
  for (const shape of [...shapes].sort((a, b) => b.length - a.length)) {
    const covered = shape.every((p) => kept.some((k) => k.some((a, i) => i > 0 && metersToSegment(p, k[i - 1], a) < toleranceMeters)));
    if (!kept.length || !covered) kept.push(shape);
  }
  // Join a piece onto another whose end it starts at (or ends at, turned around).
  const near = (a: [number, number], b: [number, number]) => metersBetween({ lat: a[0], lon: a[1] }, { lat: b[0], lon: b[1] }) < toleranceMeters * 1.5;
  let joined = true;
  while (joined) {
    joined = false;
    outer: for (let i = 0; i < kept.length; i++) {
      for (let j = 0; j < kept.length; j++) {
        if (i === j) continue;
        const [a, b] = [kept[i], kept[j]];
        for (const next of [b, [...b].reverse()]) {
          if (near(a[a.length - 1], next[0])) {
            kept[i] = [...a, ...next.slice(1)];
            kept.splice(j, 1);
            joined = true;
            break outer;
          }
        }
      }
    }
  }
  return kept;
}

/** Meters from `p` to the segment a–b, flat-earth. */
function metersToSegment(p: [number, number], a: [number, number], b: [number, number]): number {
  const scale = Math.cos((p[0] * Math.PI) / 180) * 111_320;
  const [px, py, ax, ay, bx, by] = [p[1] * scale, p[0] * 110_540, a[1] * scale, a[0] * 110_540, b[1] * scale, b[0] * 110_540];
  const [dx, dy] = [bx - ax, by - ay];
  const length = dx * dx + dy * dy;
  const t = length > 0 ? Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / length)) : 0;
  return Math.hypot(ax + t * dx - px, ay + t * dy - py);
}

/** A stop for the map of every stop: where it is and, where that's known without asking, its lines. */
export interface MapStop {
  code: string;
  lat: number;
  lon: number;
  lines?: string[];
}

/** Every stop on `lines` once, with the lines that stop there. */
export function stopsOfLines(lines: { id: string; directions: { stops: { code: string; lat?: number; lon?: number }[] }[] }[]): MapStop[] {
  const stops = new Map<string, MapStop & { lines: string[] }>();
  for (const line of lines) {
    for (const stop of line.directions.flatMap((d) => d.stops)) {
      if (!Number.isFinite(stop.lat) || !Number.isFinite(stop.lon)) continue;
      const entry = stops.get(stop.code) ?? { code: stop.code, lat: Math.round(stop.lat! * 1e5) / 1e5, lon: Math.round(stop.lon! * 1e5) / 1e5, lines: [] };
      if (!entry.lines.includes(line.id)) entry.lines.push(line.id);
      stops.set(stop.code, entry);
    }
  }
  return [...stops.values()];
}
