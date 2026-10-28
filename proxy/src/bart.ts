/**
 * BART, part of San Francisco next to Muni, from BART's GTFS-realtime feed (no key needed). The
 * network (lines by color, each with an "N" and "S" direction, stops as platform ids like "M16-1")
 * is bundled as bart.json, built from BART's static GTFS by scripts/bart.py. The feed names only the
 * trip, so bart.json also says which line and direction each scheduled trip is; a trip it doesn't
 * know (after a schedule change) is placed by the stops it still has ahead.
 *
 * Served under the SF endpoints (see index.ts): a stop id like "M16-1" is BART's.
 */

import network from "./bart.json";
import { closestPerLine, linePairs, metersBetween, NEARBY_METERS, stopsOfLines, type NearbyLine, type Polyline } from "./geo";
import { decodeFeed, type Trip } from "./nyc";

const FEED = "https://api.bart.gov/gtfsrt/tripupdate.aspx";
const FEED_TTL_MS = 30_000;

interface Stop {
  code: string;
  name: string;
  lat: number;
  lon: number;
}

interface Direction {
  id: string;
  name: string;
  destination: string;
  stops: Stop[];
  shapes: Polyline[];
}

interface Line {
  id: string;
  name: string;
  mode: string;
  color: string;
  textColor: string;
  directions: Direction[];
}

const LINES = network.lines as Line[];
const TRIPS = network.trips as Record<string, string>;
const STOPS = new Map<string, Stop>(LINES.flatMap((l) => l.directions.flatMap((d) => d.stops.map((s) => [s.code, s] as const))));

export const BART_STOP = /^[A-Z]\d+-\d$/;

export function isBartLine(id: string) {
  return LINES.some((l) => l.id === id);
}

/** The lines as the SF line list wants them. */
export function bartLines() {
  return LINES.map(({ id, name, mode }) => ({ id, name, mode }));
}

/** The lines for the SF line map. */
export function bartMap() {
  return LINES.map(({ id, name, mode, color, textColor, directions }) => ({
    id, name, mode, color, textColor,
    shapes: [...directions].sort((a, b) => b.shapes.length - a.shapes.length)[0]?.shapes ?? [],
  }));
}

/** Every platform, for the SF map of every stop. */
export function bartStops() {
  return stopsOfLines(LINES);
}

export async function handleBart(path: string, url: URL): Promise<{ body: unknown; status?: number; maxAge?: number }> {
  if (path.startsWith("lines/")) {
    const line = LINES.find((l) => l.id === decodeURIComponent(path.slice("lines/".length)));
    if (!line) return { body: { error: "unknown line" }, status: 404 };
    return { body: { line: line.id, directions: line.directions, fetchedAt: new Date().toISOString() }, maxAge: 3600 };
  }

  const stop = url.searchParams.get("stop") ?? "";

  if (path === "stop") {
    if (!STOPS.has(stop)) return { body: { error: "unknown stop" }, status: 400 };
    return { body: { stop: { code: stop, name: STOPS.get(stop)!.name }, lines: linesAt(stop) } };
  }

  if (path === "nearby") {
    const here = STOPS.get(stop);
    if (!here) return { body: { error: "unknown stop" }, status: 400 };
    // Other lines through this station (its platforms share a code before the dash), the way this
    // platform's own lines go, or any platform within a short walk.
    const ways = new Set(linesAt(stop).map((l) => l.direction));
    const found: NearbyLine[] = [];
    for (const [code, other] of STOPS) {
      const sameStation = code.split("-")[0] === stop.split("-")[0];
      const distance = sameStation ? 0 : Math.round(metersBetween(here, other));
      if (!sameStation && distance > NEARBY_METERS) continue;
      for (const l of linesAt(code)) {
        if (ways.has(l.direction)) found.push({ ...l, stop: code, stopName: other.name, distance, lat: other.lat, lon: other.lon });
      }
    }
    return { body: { stop: { code: stop }, lines: closestPerLine(found) } };
  }

  if (path === "departures") {
    const code = url.searchParams.get("line");
    if (!code || !stop.split(",").every((s) => STOPS.has(s))) return { body: { error: "stop and line are required" }, status: 400 };
    const wanted = linePairs(code, url.searchParams.get("direction"), stop);
    const feed = await loadFeed();
    const now = Date.now();
    const departures = feed.trips
      .flatMap((trip) => {
        const [line, way] = lineOf(trip);
        // The feed lists only a train's next several stops, so its last one isn't where it's going.
        const destination = LINES.find((l) => l.id === line)?.directions.find((d) => d.id === way)?.destination ?? "";
        return trip.stops.flatMap((s) => {
          const match = wanted.find((w) => w.line === line && w.stop === s.stop && (!w.direction || w.direction === way));
          if (!match || !s.time) return [];
          return [{ line, time: new Date(s.time * 1000).toISOString(), live: true, destination }];
        });
      })
      .filter((d) => Date.parse(d.time) > now - 30_000)
      .sort((a, b) => Date.parse(a.time) - Date.parse(b.time))
      .slice(0, 20);
    const first = wanted[0]?.stop ?? stop;
    return {
      body: {
        stop: { code: first, name: STOPS.get(first)?.name ?? "" },
        line: code,
        fetchedAt: new Date(feed.fetchedAt).toISOString(),
        nextRefreshAt: new Date(feed.fetchedAt + FEED_TTL_MS + 2_000).toISOString(),
        stale: now - feed.fetchedAt > FEED_TTL_MS * 4,
        departures,
      },
    };
  }

  return { body: { error: "not found" }, status: 404 };
}

/** The lines that stop at a platform, each with its direction there. */
function linesAt(stop: string) {
  return LINES.flatMap((l) => l.directions
    .filter((d) => d.stops.some((s) => s.code === stop))
    .map((d) => ({ line: l.id, direction: d.id, destination: d.destination })));
}

/** A trip's line and direction: from the schedule, or else the first whose stops hold all those ahead. */
function lineOf(trip: Trip): [string, string] {
  const known = trip.id ? TRIPS[trip.id] : undefined;
  if (known) return known.split("|") as [string, string];
  const ahead = trip.stops.map((s) => s.stop);
  for (const line of LINES) {
    for (const direction of line.directions) {
      const codes = direction.stops.map((s) => s.code);
      if (ahead.every((s) => codes.includes(s))) return [line.id, direction.id];
    }
  }
  return ["", ""];
}

interface Feed {
  trips: Trip[];
  fetchedAt: number;
}

let feed: Promise<Feed> | undefined;

/** The feed, fetched at most every FEED_TTL_MS; on a hiccup the last copy is served (and says it's stale). */
async function loadFeed(): Promise<Feed> {
  const cached = feed;
  const last = await cached?.catch(() => undefined);
  if (last && Date.now() - last.fetchedAt < FEED_TTL_MS) return last;
  if (cached && feed !== cached) return feed!;
  const load = fetch(FEED)
    .then(async (response) => {
      if (!response.ok) throw new Error(`BART feed: ${response.status}`);
      return { trips: decodeFeed(new Uint8Array(await response.arrayBuffer())), fetchedAt: Date.now() };
    })
    .catch((error) => {
      if (last) return { ...last };
      feed = undefined;
      throw error;
    });
  feed = load;
  return load;
}
