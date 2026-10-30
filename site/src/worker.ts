// The site is static files, except for /s, a shared stop: its link preview (what Messages, WhatsApp
// and friends show for the link) names the line and stop rather than any old bus, looked up from the
// proxy like the page itself does, with /s/card.png, the stop's card with its current wait and a map
// of the buses on their way, as the picture. /mapkit-token signs the page's live map in.

import { MAP_WIDTH, renderCard, type BadgePart, type CardMap } from "./card";
import { mapkitToken, project, snapshot, unproject, type MapKitEnv, type Point } from "./mapkit";

interface Env extends MapKitEnv {
  ASSETS: { fetch(request: Request): Promise<Response> };
}

const SITE = "https://37shadesoflate.com";
/** Where the page's map may run: the site, its workers.dev address, and a local `wrangler dev`. */
const ALLOWED_ORIGINS = /^(https:\/\/(www\.)?37shadesoflate\.com|https:\/\/37shadesoflate-site\.arne-5c1\.workers\.dev|http:\/\/localhost:\d+)$/;

const API = "https://bus37-proxy.arne-5c1.workers.dev/v1/";

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/s/card.png") return card(request, url, env, ctx);
    if (url.pathname === "/mapkit-token") {
      // For the page asking (its address, from the Referer), if it's one of the site's own; a token
      // only works on the address it names.
      const page = (() => { try { return new URL(request.headers.get("Referer") ?? "").origin; } catch { return ""; } })();
      const origin = ALLOWED_ORIGINS.test(page) ? page : SITE;
      const token = await mapkitToken(env, origin);
      return new Response(token ?? "", { status: token ? 200 : 503, headers: { "Content-Type": "text/plain", "Cache-Control": "no-store" } });
    }
    const page = await env.ASSETS.fetch(request);
    if (url.pathname !== "/s" || !page.ok) return page;
    const ride = await lookUp(url.searchParams).catch(() => undefined);
    if (!ride) return page;
    const title = `The ${ride.line} at ${ride.stop}`;
    const description = `Live minutes until the ${ride.line} to ${ride.destination} shows up, and how to feel about it.`;
    // Always https: previews won't fetch a picture over plain http.
    const image = `https://${url.host}/s/card.png${url.search}`;
    const set = (content: string) => ({ element: (tag: Element) => { tag.setAttribute("content", content); } });
    return new HTMLRewriter()
      .on('meta[property="og:title"]', set(title))
      .on('meta[property="og:description"]', set(description))
      .on('meta[name="description"]', set(description))
      .on('meta[property="og:image"]', set(image))
      .on('meta[name="twitter:image"]', set(image))
      .on("title", { element: (tag) => { tag.setInnerContent(`${title} · 37 Shades of Late`); } })
      .transform(page);
  },
};

/** The stop's card, with its wait as of now; kept for a minute, as previews are fetched in bursts. */
async function card(request: Request, url: URL, env: Env, ctx: ExecutionContext): Promise<Response> {
  const cache = (caches as unknown as { default: Cache }).default;
  const cached = await cache.match(request);
  if (cached) return cached;
  const ride = await lookUp(url.searchParams).catch(() => undefined);
  if (!ride) return new Response("not found", { status: 404 });
  const upcoming = (await departures(url.searchParams).catch(() => []))
    .filter((d) => Date.parse(d.time) > Date.now() - 30_000).slice(0, 3);
  const minutes = upcoming.map((d) => Math.max(0, Math.floor((Date.parse(d.time) - Date.now()) / 60_000)));
  const map = await cardMap(env, ride, upcoming.map((d, i) => ({ ...d, label: minutes[i] === 0 ? "now" : String(minutes[i]) })))
    .catch(() => undefined);
  const png = await renderCard({
    badge: ride.badge,
    round: ride.round,
    parts: ride.parts,
    lineBadges: ride.combined ? Object.fromEntries(upcoming.map((d) => d.line ?? "").filter(Boolean)
      .map((id) => [id, lineBadge(id, url.searchParams.get("c") ?? "sf")])) : undefined,
    destination: ride.destination,
    stop: ride.stop,
    minutes,
    live: upcoming[0]?.live ?? false,
    lines: ride.combined ? upcoming.map((d) => d.line ?? "") : undefined,
    quip: minutes.length ? quip(minutes[0], said(upcoming[0].line || ride.first, url.searchParams.get("c") ?? "sf")) : `Schrödinger's ${ride.line}: both coming and not coming.`,
    map,
  });
  const response = new Response(png, { headers: { "Content-Type": "image/png", "Cache-Control": "public, max-age=60" } });
  ctx.waitUntil(cache.put(request, response.clone()));
  return response;
}

/** The card's map: the stop and the buses on their way to it, with a bit of the route around them. */
async function cardMap(env: Env, ride: Ride, buses: { vehicle?: Point; live: boolean; label: string }[]): Promise<CardMap | undefined> {
  const size = { width: MAP_WIDTH, height: 630 };
  const near = buses.filter((b) => b.vehicle && meters(b.vehicle, ride.at) < 8_000).slice(0, 3);
  // The stop and the buses, with room around them; at least a few blocks across.
  const points = [ride.at, ...near.map((b) => b.vehicle!)];
  // The closest zoom that fits them (16 at most: a few blocks across).
  const z = [16, 15, 14, 13, 12, 11].find((z) => {
    const xy = points.map((p) => project(p, z));
    const span = (values: number[]) => Math.max(...values) - Math.min(...values);
    return span(xy.map((p) => p.x)) <= size.width * 0.6 && span(xy.map((p) => p.y)) <= size.height * 0.6;
  }) ?? 11;
  const xy = points.map((p) => project(p, z));
  const middle = { x: (Math.min(...xy.map((p) => p.x)) + Math.max(...xy.map((p) => p.x))) / 2,
                   y: (Math.min(...xy.map((p) => p.y)) + Math.max(...xy.map((p) => p.y))) / 2 };
  const center = unproject(middle.x, middle.y, z);
  const png = await snapshot(env, center, z, size);
  if (!png) return undefined;
  const place = (p: Point) => { const q = project(p, z); return { x: q.x - middle.x + size.width / 2, y: q.y - middle.y + size.height / 2 }; };
  return {
    png,
    route: ride.route.map((line) => line.map(place)),
    stop: place(ride.at),
    buses: near.map((b) => ({ ...place(b.vehicle!), label: b.label, live: b.live })),
  };
}

function meters(a: Point, b: Point): number {
  return Math.hypot((b.lon - a.lon) * 111_320 * Math.cos((a.lat * Math.PI) / 180), (b.lat - a.lat) * 110_540);
}

/** As the page's own quips (pages/s.html). */
/** A line as a sentence says it: Boston's subway by its full name ("the Red Line", "the Green Line B",
 * as the MBTA does), every other as it's called ("the 37", "the N"). As the page's (pages/s.html). */
function said(id: string, city: string): string {
  if (city === "chicago") return id in CHICAGO_L ? `${id} Line` : id;
  if (city !== "boston") return id;
  if (/^[BCDE]$/.test(id)) return `Green Line ${id}`;
  return ["Red", "Orange", "Blue", "Mattapan"].includes(id) ? `${id} Line` : id;
}

function quip(minutes: number, line: string): string {
  if (minutes < 4) return `Holy shit, the ${line} is real.`;
  if (minutes < 9) return "Stay put, lazy bastard.";
  if (minutes < 16) return "Make coffee. Reconsider your life.";
  return "Walking is starting to look attractive.";
}

/** The base URL of the proxy for the link's city, or nothing for one it doesn't know. */
function base(params: URLSearchParams): string | undefined {
  const city = params.get("c") ?? "sf";
  return /^(sf|seattle|nyc|boston|chicago)$/.test(city) ? API + (city === "sf" ? "" : city + "/") : undefined;
}

interface Ride {
  line: string;
  first: string;
  badge: string;
  /** See `isRound`. */
  round: boolean;
  /** See `badgeParts`. */
  parts: BadgePart[];
  combined: boolean;
  stop: string;
  destination: string;
  /** Where the stop is, and the first line's route (its shape, or its stops in order). */
  at: Point;
  route: Point[][];
}

/** Whether `ids` all have famously round badges, as the app's (LineBadge.isRound): New York's subway
 * (one letter or number, and the S shuttles; its buses all have more), Muni Metro's J, K, L, M, N, T
 * and its historic streetcars, the E and F, BART's lines, and Sound Transit's 1, 2, T, N and S Lines. */
function isRound(ids: string[], city: string): boolean {
  return ids.every((id) => city === "nyc" ? id.length === 1 || id.startsWith("S ")
    : city === "sf" ? /^[EFJKLMNT]$/.test(id) || id in BART_INITIALS
    : city === "seattle" ? /^[12TNS] Line$/.test(id)
    : city === "boston" ? id in BOSTON_SUBWAY
    : city === "chicago" && id in CHICAGO_L);
}

/** What a round badge says, as the app's (LineBadge.short): BART's Yellow a "Y", Sound Transit's
 * "1 Line" a "1", Boston's Red Line an "RL" (Red, Orange and Blue are lines in both cities). */
const short = (id: string, city: string) => city === "sf" ? BART_INITIALS[id] ?? id
  : city === "boston" ? BOSTON_SUBWAY[id]?.[0] ?? id
  : city === "chicago" ? CHICAGO_L[id]?.[0] ?? id
  : id.endsWith(" Line") ? id.slice(0, -5) : id;

/** Chicago's 'L', as the app's (LineBadge.chicagoL): what its circles say, in its colors. */
const CHICAGO_L: Record<string, [string, string]> = {
  Red: ["R", "#C60C30"], Blue: ["B", "#00A1DE"], Brown: ["BR", "#62361B"], Green: ["G", "#009B3A"],
  Orange: ["O", "#F9461C"], Purple: ["P", "#522398"], Pink: ["PK", "#E27EA6"], Yellow: ["Y", "#F9E300"],
};

/** Boston's subway, as the app's (LineBadge.bostonSubway): what its circles say, in its colors. */
const BOSTON_SUBWAY: Record<string, [string, string]> = {
  Red: ["RL", "#DA291C"], Orange: ["OL", "#ED8B00"], Blue: ["BL", "#003DA5"], Mattapan: ["M", "#DA291C"],
  B: ["B", "#00843D"], C: ["C", "#00843D"], D: ["D", "#00843D"], E: ["E", "#00843D"],
};

/** BART's lines, by their colors, as the app's (LineBadge.short). */
const BART_INITIALS: Record<string, string> = { Red: "R", Orange: "O", Yellow: "Y", Green: "G", Blue: "B", OAK: "OAK" };

/** The colors of the lines with badges of their own, as the app's (LineBadge.color): "#RRGGBB", and
 * whether the letters on it are black (New York's yellow lines). The round ones, BART's lines, and
 * Seattle's RapidRide in its dark red. */
const COLORS: Record<string, Record<string, [string, boolean]>> = {
  nyc: { "1": ["#D82233", false], "2": ["#D82233", false], "3": ["#D82233", false],
         "4": ["#009952", false], "5": ["#009952", false], "6": ["#009952", false], "7": ["#9A38A1", false],
         A: ["#0062CF", false], C: ["#0062CF", false], E: ["#0062CF", false],
         B: ["#EB6800", false], D: ["#EB6800", false], F: ["#EB6800", false], M: ["#EB6800", false],
         G: ["#799534", false], J: ["#8E5C33", false], Z: ["#8E5C33", false], L: ["#7C858C", false],
         N: ["#F6BC26", true], Q: ["#F6BC26", true], R: ["#F6BC26", true], W: ["#F6BC26", true] },
  sf: { J: ["#A96614", false], K: ["#437C93", false], L: ["#942D83", false], M: ["#008547", false],
        N: ["#005B95", false], T: ["#BF2B45", false], F: ["#B49A36", true], E: ["#666666", false],
        Red: ["#FF0000", false], Orange: ["#FF9933", true], Yellow: ["#FFFF33", true], Green: ["#339933", false],
        Blue: ["#0099CC", false], OAK: ["#B0BEC7", true] },
  seattle: { "1 Line": ["#28813F", false], "2 Line": ["#007CAD", false], "T Line": ["#F38B00", true],
             "N Line": ["#9AB6D3", true], "S Line": ["#9AB6D3", true],
             ...Object.fromEntries("ABCDEFGH".split("").map((l) => [`${l} Line`, ["#9C182F", false] as [string, boolean]])) },
};

function colorOf(id: string, city: string): [string, boolean] | undefined {
  if (city === "chicago") return CHICAGO_L[id] ? [CHICAGO_L[id][1], id === "Yellow"] : undefined;
  if (city === "boston") {
    // The subway's colors; the rest by what they are (the app also knows commuter rail and ferries).
    if (BOSTON_SUBWAY[id]) return [BOSTON_SUBWAY[id][1], false];
    if (id.startsWith("SL")) return ["#7C878E", false];
    if (/^(\d|CT)/.test(id)) return ["#FFC72C", true];
    return undefined;
  }
  return COLORS[city]?.[id] ?? (city === "nyc" && id.startsWith("S ") ? ["#7C858C", false] : undefined);
}

/** A link's badges, as the app's (Selection.badgeParts): one in the app's red, except for lines with
 * badges of their own: subway, Muni Metro and Sound Transit lines come round and in their colors, a
 * circle each, those sharing a color next to each other (the A, C and E in three blue circles), and
 * RapidRide in its dark red. Any others with them share
 * a red rectangle (the K, L and M in their circles, then a 24). */
function badgeParts(ids: string[], city: string): BadgePart[] {
  const join = (group: string[]) => group.join(group.every((id) => id.length === 1) ? "" : "·");
  if (!ids.some((id) => colorOf(id, city))) return [{ label: join(ids) }];
  const groups: { color?: [string, boolean]; round: boolean; ids: string[] }[] = [];
  for (const id of ids) {
    const color = colorOf(id, city), round = isRound([id], city);
    const group = groups.find((g) => g.color?.[0] === color?.[0] && g.round === round);
    if (group) group.ids.push(id); else groups.push({ color, round, ids: [id] });
  }
  return groups.flatMap((g) => g.round
    ? g.ids.map((id) => ({ label: short(id, city), color: g.color?.[0], dark: g.color?.[1], round: true }))
    : [{ label: join(g.ids), color: g.color?.[0], dark: g.color?.[1], round: false }]);
}

/** One line's badge, as on the line map: round and in its color where it has one, else a rectangle
 * in its color or red. */
function lineBadge(id: string, city: string): BadgePart & { round: boolean } {
  const color = colorOf(id, city), round = isRound([id], city);
  return { label: round ? short(id, city) : id, color: color?.[0], dark: color?.[1], round };
}

/** The line, stop and destination a shared link points to: /s?c=sf&l=37&s=13254&d=IB. Combined lines
 * come as lists (l=K,L,M&d=IB,IB,IB); the stop and destination are the first one's, and `line` names them all. */
async function lookUp(params: URLSearchParams): Promise<Ride | undefined> {
  const ids = (params.get("l") ?? "").split(",").filter(Boolean);
  const [line, stop, way] = [ids[0], params.get("s")?.split(",")[0], params.get("d")?.split(",")[0]];
  const api = base(params);
  if (!line || !stop || !api) return undefined;
  const response = await fetch(`${api}lines/${encodeURIComponent(line)}?client=web`, { cf: { cacheTtl: 3600 } });
  if (!response.ok) return undefined;
  const data: { directions?: { id: string; destination: string; stops: { code: string; name: string; lat?: number; lon?: number }[]; shapes?: number[][][] }[] } = await response.json();
  const directions = data.directions ?? [];
  const direction = directions.find((d) => d.id === way && d.stops.some((s) => s.code === stop))
    ?? directions.find((d) => d.stops.some((s) => s.code === stop));
  const here = direction?.stops.find((s) => s.code === stop);
  const name = here?.name;
  const city = params.get("c") ?? "sf";
  const names = ids.map((id) => said(id, city));
  const spoken = names.length > 1 ? names.slice(0, -1).join(", ") + " or " + names[names.length - 1] : names[0];
  // As the app's badges: "37", "KLM", "5·21".
  const badge = ids.join(ids.every((id) => id.length === 1) ? "" : "·");
  if (!direction || !name || here?.lat === undefined || here.lon === undefined) return undefined;
  const route = direction.shapes?.length
    ? direction.shapes.map((shape) => shape.map(([lat, lon]) => ({ lat, lon })))
    : [direction.stops.filter((s) => s.lat !== undefined && s.lon !== undefined).map((s) => ({ lat: s.lat!, lon: s.lon! }))];
  return { line: spoken, first: line, badge, round: isRound(ids, params.get("c") ?? "sf"),
           parts: badgeParts(ids, params.get("c") ?? "sf"), combined: ids.length > 1, stop: name, destination: direction.destination,
           at: { lat: here.lat, lon: here.lon }, route };
}

/** The link's departures, all its lines merged, as the page asks for them. */
async function departures(params: URLSearchParams): Promise<{ time: string; live: boolean; line?: string; vehicle?: Point }[]> {
  const api = base(params);
  if (!api) return [];
  const query = new URLSearchParams({ stop: params.get("s") ?? "", line: params.get("l") ?? "", direction: params.get("d") ?? "", client: "web" });
  const response = await fetch(`${api}departures?${query}`);
  return response.ok ? ((await response.json()) as any).departures ?? [] : [];
}
