/**
 * Washington, D.C.: WMATA's Metrorail (the Red, Orange, Blue, Silver, Green and Yellow Lines) and
 * Metrobus. The network (lines, their stops in order per direction, shapes and colors) is built ahead of
 * time from WMATA's static GTFS by scripts/dc.py into dc.json, like Chicago's. Live times and vehicles
 * come from WMATA's GTFS-realtime feeds, the whole network in four files (trip updates and vehicle
 * positions, for the trains and for the buses), fetched at most every FEED_TTL_MS and shared by every
 * stop, like Boston's. They take WMATA's key (WMATA_API_KEY): its default tier allows 50,000 calls a
 * day, and four every 20 seconds is about 17,000. Without a key, no departures. Served under
 * /v1/dc/... like Boston (see boston.ts, which serves both).
 *
 * Stop codes are GTFS stops: a train platform ("PF_A03_2", Dupont Circle's toward Shady Grove; a center
 * platform serves both ways) or a bus stop.
 */

import { decodeTrips, serveNetwork, type Line, type LiveTrip, type Visit } from "./boston";
import { decodePositions } from "./ferries";
import network from "./dc.json";

const FEEDS = "https://api.wmata.com/gtfs/";
const FEED_TTL_MS = 20_000;

export interface DCDeps {
  apiKey?: string;
}

/** dc.json's lines, its stops as [code, name, lat, lon] made into the shape every city serves. */
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

/** Which way of its line each stop is on, by route and stop: a bus's way there, as WMATA's bus feed
 *  doesn't say. A stop both ways keeps the way it's not the end of. */
const wayAt = new Map<string, string>();
for (const line of lines) {
  for (const d of line.directions) {
    for (const s of d.stops) {
      const key = `${line.routeId}|${s.code}`;
      if (!wayAt.has(key) || d.stops.at(-1)?.code !== s.code) wayAt.set(key, d.id);
    }
  }
}

export async function handleDC(parts: string[], url: URL, deps: DCDeps) {
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
    if (time === undefined) continue;
    const direction = trip.direction || wayAt.get(`${trip.route}|${stop}`);
    if (!direction) continue;
    visits.push({
      routeId: trip.route, direction,
      destination: destinations.get(trip.route)?.get(direction) ?? "",
      time: new Date(time * 1000).toISOString(),
      live: true,
      vehicle: live.positions.get(id),
    });
  }
  return visits.sort((a, b) => Date.parse(a.time) - Date.parse(b.time));
}

let live: Promise<Live> | undefined;

/** WMATA's trip updates and vehicle positions, at most every FEED_TTL_MS; the last copy on a hiccup. */
async function loadLive(apiKey: string): Promise<Live> {
  const cached = await live?.catch(() => undefined);
  if (cached && Date.now() - cached.fetchedAt < FEED_TTL_MS) return cached;
  const next = (async () => {
    const get = async (name: string) => {
      const response = await fetch(FEEDS + name, { headers: { api_key: apiKey } });
      if (!response.ok) throw new Error(`WMATA ${name}: ${response.status}`);
      return new Uint8Array(await response.arrayBuffer());
    };
    const [rail, bus, railAt, busAt] = await Promise.all([
      get("rail-gtfsrt-tripupdates.pb"), get("bus-gtfsrt-tripupdates.pb"),
      get("rail-gtfsrt-vehiclepositions.pb").catch(() => undefined), get("bus-gtfsrt-vehiclepositions.pb").catch(() => undefined),
    ]);
    return {
      trips: new Map([...decodeTrips(rail, true), ...decodeTrips(bus, true)]),
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
