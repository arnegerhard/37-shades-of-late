/**
 * Los Angeles: LA Metro's rail (the A, B, C, D, E and K Lines), its G and J busways and its buses. The
 * network (lines, their stops in order per direction, shapes and colors) is built ahead of time from
 * Metro's static GTFS by scripts/la.py into la.json, like Chicago's. Live times and vehicles come from
 * Metro's GTFS-realtime feeds, which Swiftly serves for it: the whole network in four files (trip updates
 * and vehicle positions, for the trains and for the buses), fetched at most every FEED_TTL_MS and shared
 * by every stop, like Washington's. They take a Swiftly key (SWIFTLY_API_KEY, which Metro's developer
 * page sends for). Without a key, no departures. Served under /v1/la/... like Boston (see boston.ts,
 * which serves both).
 *
 * Stop codes are GTFS stops: a rail station ("80203", Hollywood / Highland, both ways) or a bus stop.
 */

import { decodeTrips, serveNetwork, type Line, type LiveTrip, type Visit } from "./boston";
import { decodePositions } from "./ferries";
import network from "./la.json";

/** Bus and rail, by Swiftly's names for them. */
const FEEDS = ["https://api.goswift.ly/real-time/lametro/", "https://api.goswift.ly/real-time/lametro-rail/"];
const FEED_TTL_MS = 20_000;

export interface LADeps {
  apiKey?: string;
}

/** la.json's lines, its stops as [code, name, lat, lon] made into the shape every city serves. */
const lines: Line[] = (network as any).lines.map((l: any) => ({
  ...l,
  color: l.color ?? undefined,
  textColor: l.textColor ?? undefined,
  directions: l.directions.map((d: any) => ({
    id: d.id, name: d.destination, destination: d.destination, shapes: d.shapes,
    stops: d.stops.map(([code, name, lat, lon]: [string, string, number, number]) => ({ code, name, lat, lon })),
  })),
}));

const destinations = new Map(lines.map((l) => [l.routeId, new Map(l.directions.map((d) => [d.id, d.destination]))]));

/** The network's route for a live trip's: the same, or ("2" for "2-13201") the schedule's with its
 *  service period on the end, which the live feeds may leave off. */
const routeIds = new Map(lines.flatMap((l) => [[l.routeId, l.routeId], [l.routeId.split("-")[0], l.routeId]]));

/** Which way of its line each stop is on, by route and stop: a trip's way there, should the feed not
 *  say. A stop both ways keeps the way it's not the end of. */
const wayAt = new Map<string, string>();
for (const line of lines) {
  for (const d of line.directions) {
    for (const s of d.stops) {
      const key = `${line.routeId}|${s.code}`;
      if (!wayAt.has(key) || d.stops.at(-1)?.code !== s.code) wayAt.set(key, d.id);
    }
  }
}

export async function handleLA(parts: string[], url: URL, deps: LADeps) {
  return serveNetwork(parts, url, lines, async (stopCodes) => {
    if (!deps.apiKey) return { visits: stopCodes.map(() => []), fetchedAt: Date.now(), ttl: FEED_TTL_MS };
    const live = await loadLive(deps.apiKey);
    return { visits: stopCodes.map((stop) => visitsAt(stop, live)), fetchedAt: live.fetchedAt, ttl: FEED_TTL_MS };
  });
}

interface Live {
  trips: Map<string, LiveTrip>;
  positions: Map<string, { lat: number; lon: number; bearing?: number }>;
  fetchedAt: number;
}

function visitsAt(stop: string, live: Live): Visit[] {
  const visits: Visit[] = [];
  for (const [id, trip] of live.trips) {
    const time = trip.stops.get(stop);
    const route = routeIds.get(trip.route);
    if (time === undefined || !route) continue;
    const direction = trip.direction || wayAt.get(`${route}|${stop}`);
    if (!direction) continue;
    visits.push({
      routeId: route, direction,
      destination: destinations.get(route)?.get(direction) ?? "",
      time: new Date(time * 1000).toISOString(),
      live: true,
      vehicle: live.positions.get(id),
    });
  }
  return visits.sort((a, b) => Date.parse(a.time) - Date.parse(b.time));
}

let live: Promise<Live> | undefined;

/** Metro's trip updates and vehicle positions, at most every FEED_TTL_MS; the last copy on a hiccup. */
async function loadLive(apiKey: string): Promise<Live> {
  const cached = await live?.catch(() => undefined);
  if (cached && Date.now() - cached.fetchedAt < FEED_TTL_MS) return cached;
  const next = (async () => {
    const get = async (name: string) => {
      const response = await fetch(name, { headers: { Authorization: apiKey } });
      if (!response.ok) throw new Error(`Swiftly ${name}: ${response.status}`);
      return new Uint8Array(await response.arrayBuffer());
    };
    const [bus, rail] = FEEDS;
    const [busTrips, railTrips, busAt, railAt] = await Promise.all([
      get(bus + "gtfs-rt-trip-updates"), get(rail + "gtfs-rt-trip-updates"),
      get(bus + "gtfs-rt-vehicle-positions").catch(() => undefined), get(rail + "gtfs-rt-vehicle-positions").catch(() => undefined),
    ]);
    return {
      trips: new Map([...decodeTrips(railTrips, true), ...decodeTrips(busTrips, true)]),
      positions: new Map([...(railAt ? decodePositions(railAt) : []), ...(busAt ? decodePositions(busAt) : [])]),
      fetchedAt: Date.now(),
    };
  })();
  live = next.catch((error) => {
    if (cached) return cached;
    throw error;
  });
  return live;
}
