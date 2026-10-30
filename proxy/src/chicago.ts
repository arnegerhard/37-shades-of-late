/**
 * Chicago: the CTA's 'L' (Red, Blue, Brown, Green, Orange, Purple, Pink and Yellow Lines) and its buses.
 * The network (lines, their stops in order per direction, shapes and colors) is built ahead of time from
 * the CTA's static GTFS by scripts/chicago.py into chicago.json, as its schedule is far too big to read
 * here. Live times and vehicles come from the CTA's GTFS-realtime feeds, the whole network in two files,
 * fetched at most every FEED_TTL_MS and shared by every stop, like Boston's; they need a key
 * (CTA_API_KEY, from the CTA's developer center). Without one, stops have no departures. Served under
 * /v1/chicago/... like Boston (see boston.ts, which serves both).
 *
 * The Brown, Orange, Pink and Purple Lines run out and back as one trip; the network splits them into
 * "out" (toward the Loop) and "back", and a live trip's way at a stop is the one that stop is on.
 */

import { decodeTrips, serveNetwork, type Line, type LiveTrip, type Visit } from "./boston";
import { decodePositions } from "./ferries";
import network from "./chicago.json";

const FEEDS = "https://transitdata.transitchicago.com/GtfsRealtime/";
const FEED_TTL_MS = 20_000;

interface Live {
  trips: Map<string, LiveTrip>;
  positions: Map<string, { lat: number; lon: number; bearing?: number }>;
  fetchedAt: number;
}

/** chicago.json's lines, its stops as [code, name, lat, lon] made into the shape every city serves. */
const lines: Line[] = (network as any).lines.map((l: any) => ({
  ...l,
  color: l.color ?? undefined,
  textColor: l.textColor ?? undefined,
  directions: l.directions.map((d: any) => ({
    id: d.id, name: d.destination, destination: d.destination, shapes: d.shapes,
    stops: d.stops.map(([code, name, lat, lon]: [string, string, number, number]) => ({ code, name, lat, lon })),
  })),
}));

/** Which way of its line each stop is on, by route and stop: a live trip's way there. */
const wayAt = new Map<string, { direction: string; destination: string }>();
for (const line of lines) {
  for (const d of line.directions) {
    for (const s of d.stops) {
      const key = `${line.routeId}|${s.code}`;
      // A stop both ways (a terminal, the Loop's turnaround) keeps the way it's not the end of.
      if (!wayAt.has(key) || d.stops.at(-1)?.code !== s.code) wayAt.set(key, { direction: d.id, destination: d.destination });
    }
  }
}

export async function handleChicago(parts: string[], url: URL, apiKey?: string) {
  return serveNetwork(parts, url, lines, async (stopCodes) => {
    const live = apiKey ? await loadLive(apiKey) : { trips: new Map(), positions: new Map(), fetchedAt: Date.now() };
    return { visits: stopCodes.map((s) => visitsAt(s, live)), fetchedAt: live.fetchedAt, ttl: FEED_TTL_MS };
  });
}

function visitsAt(stop: string, live: Live): Visit[] {
  const visits: Visit[] = [];
  for (const [id, trip] of live.trips) {
    const time = trip.stops.get(stop);
    const way = wayAt.get(`${trip.route}|${stop}`);
    if (time === undefined || !way) continue;
    visits.push({
      routeId: trip.route,
      direction: way.direction,
      destination: way.destination,
      time: new Date(time * 1000).toISOString(),
      live: true,
      vehicle: live.positions.get(id),
    });
  }
  return visits.sort((a, b) => Date.parse(a.time) - Date.parse(b.time));
}

let live: Promise<Live> | undefined;

/** The CTA's trip updates and vehicle positions, at most every FEED_TTL_MS; the last copy on a hiccup. */
async function loadLive(key: string): Promise<Live> {
  const cached = await live?.catch(() => undefined);
  if (cached && Date.now() - cached.fetchedAt < FEED_TTL_MS) return cached;
  const next = (async () => {
    const get = async (name: string) => {
      const response = await fetch(`${FEEDS}${name}?key=${encodeURIComponent(key)}`);
      if (!response.ok) throw new Error(`CTA ${name}: ${response.status}`);
      const bytes = new Uint8Array(await response.arrayBuffer());
      // A refused key comes back as a little XML document (in UTF-16), with a 200.
      const head = new TextDecoder(bytes[0] === 0xff || bytes[0] === 0xfe ? "utf-16" : "utf-8").decode(bytes.subarray(0, 600));
      if (head.trimStart().startsWith("<")) throw new Error(`CTA ${name}: ${head.match(/<errNm>([^<]*)/)?.[1] ?? "not a feed"}`);
      return bytes;
    };
    const [updates, positions] = await Promise.all([get("TripUpdates.pb"), get("VehiclePositions.pb").catch(() => undefined)]);
    return { trips: decodeTrips(updates), positions: positions ? decodePositions(positions) : new Map(), fetchedAt: Date.now() };
  })();
  live = next.catch((error) => {
    if (cached) return cached;
    throw error;
  });
  return live;
}
