/**
 * Los Angeles: LA Metro's rail (the A, B, C, D, E and K Lines), its G and J busways and its buses. The
 * network (lines, their stops in order per direction, shapes and colors) is built ahead of time from
 * Metro's static GTFS by scripts/la.py into la.json, like Chicago's. Live times and vehicles come from
 * Metro's GTFS-realtime feeds, the whole network at once (trip updates and vehicle positions, for the
 * trains and for the buses), at most every FEED_TTL_MS and shared by every stop, like Washington's. From
 * Swiftly's files with a Swiftly key (SWIFTLY_API_KEY); without one, from Metro's own WebSockets
 * (api.metro.net/ws), which need none: each sends the whole state over again every few seconds, as
 * JSON, so a connection is held just long enough for one round. Served under /v1/la/... like Boston
 * (see boston.ts, which serves both).
 *
 * Stop codes are GTFS stops: a rail station ("80203", Hollywood / Highland, both ways) or a bus stop.
 */

import { decodeTrips, serveNetwork, type Line, type LiveTrip, type Visit } from "./boston";
import { decodePositions } from "./ferries";
import network from "./la.json";

/** Bus and rail, by Swiftly's names for them. */
const FEEDS = ["https://api.goswift.ly/real-time/lametro/", "https://api.goswift.ly/real-time/lametro-rail/"];
const FEED_TTL_MS = 20_000;
/** Metro's own feeds, by agency (buses, trains) and kind. */
const SOCKETS = "https://api.metro.net/ws/";
/** A round of a socket's state is over once it's been quiet this long; past the longest, what came is it. */
const ROUND_QUIET_MS = 900;
const ROUND_LONGEST_MS = 9_000;
/** Older than this, the last copy is still served while a new one is fetched; past it, waited for. */
const STALE_MS = 3 * 60_000;

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
let lastGood: Live | undefined;

/** Metro's trip updates and vehicle positions, at most every FEED_TTL_MS; the last copy on a hiccup, and
 *  while a new one comes from the sockets (which takes a few seconds), unless it's older than STALE_MS. */
async function loadLive(apiKey?: string): Promise<Live> {
  const cached = await live?.catch(() => undefined) ?? lastGood;
  if (cached && Date.now() - cached.fetchedAt < FEED_TTL_MS) return cached;
  if (!apiKey) {
    const next = live = loadSockets(cached).then((fresh) => (lastGood = fresh)).catch((error) => {
      if (cached) return cached;
      throw error;
    });
    // Not waited for while the last copy will do: the sockets take a round to say anything.
    return cached && Date.now() - cached.fetchedAt < STALE_MS ? cached : next;
  }
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

/** One round of each of Metro's sockets: every trip's predictions and every vehicle's place, as Swiftly's
 *  files have them. A feed that says nothing this time keeps what `last` had from it. */
async function loadSockets(last?: Live): Promise<Live> {
  const [busTrips, railTrips, busAt, railAt] = await Promise.all([
    round("LACMTA/trip_updates"), round("LACMTA_Rail/trip_updates"),
    round("LACMTA/vehicle_positions"), round("LACMTA_Rail/vehicle_positions"),
  ]);
  if (!busTrips.length && !railTrips.length && !last) throw new Error("Metro's sockets sent nothing");
  const trips = new Map<string, LiveTrip>();
  const positions = new Map<string, { lat: number; lon: number; bearing?: number }>();
  // A quiet feed: its part of the last copy.
  const keep = (sent: unknown[], rail: boolean, from?: Map<string, any>, into?: Map<string, any>) => {
    if (sent.length || !from || !into) return;
    for (const [id, value] of from) if (isRail(value?.route ?? "") === rail) into.set(id, value);
  };
  for (const message of [...railTrips, ...busTrips]) tripFrom(message, trips);
  keep(railTrips, true, last?.trips, trips);
  keep(busTrips, false, last?.trips, trips);
  for (const message of [...railAt, ...busAt]) positionFrom(message, positions);
  if (!railAt.length && !busAt.length && last) for (const [id, at] of last.positions) positions.set(id, at);
  return { trips, positions, fetchedAt: Date.now() };
}

/** Metro's rail routes are 8xx ("801", the A Line); its buses are numbered otherwise. */
const isRail = (route: string) => /^8\d\d$/.test(route);

/** A socket's messages until it's had a quiet moment (a round over) or ROUND_LONGEST_MS; none on failure. */
async function round(feed: string): Promise<unknown[]> {
  let socket: WebSocket | null = null;
  try {
    const response = await fetch(SOCKETS + feed, { headers: { Upgrade: "websocket" } });
    socket = response.webSocket;
    if (!socket) return [];
    socket.accept();
  } catch {
    return [];
  }
  const ws = socket;
  return new Promise((resolve) => {
    const messages: unknown[] = [];
    let quiet: ReturnType<typeof setTimeout> | null = null;
    let longest: ReturnType<typeof setTimeout> | null = null;
    const done = () => {
      clearTimeout(quiet);
      clearTimeout(longest);
      try { ws.close(); } catch { /* gone already */ }
      resolve(messages);
    };
    longest = setTimeout(done, ROUND_LONGEST_MS);
    ws.addEventListener("message", (event) => {
      try { messages.push(JSON.parse(String(event.data))); } catch { /* not one of theirs */ }
      clearTimeout(quiet);
      quiet = setTimeout(done, ROUND_QUIET_MS);
    });
    ws.addEventListener("close", done);
    ws.addEventListener("error", done);
  });
}

/** A trip update, as decodeTrips reads Swiftly's (with arrivals): where it leaves each stop; the last stop,
 *  arrived at only, left out; skipped stops and canceled trips not at all. */
function tripFrom(message: any, into: Map<string, LiveTrip>) {
  const update = message?.tripUpdate, trip = update?.trip;
  const id = String(trip?.tripId ?? ""), route = String(trip?.routeId ?? "");
  if (!id || !route || trip?.scheduleRelationship === "CANCELED") return;
  const stops = new Map<string, number>();
  let last = "";
  for (const u of update.stopTimeUpdate ?? []) {
    const stop = String(u?.stopId ?? "");
    const departure = Number(u?.departure?.time) || 0, arrival = Number(u?.arrival?.time) || 0;
    if (!stop || u?.scheduleRelationship === "SKIPPED" || !(departure || arrival)) continue;
    stops.set(stop, departure || arrival);
    last = departure ? "" : stop;
  }
  if (last) stops.delete(last);
  if (stops.size) into.set(id, { route, direction: trip.directionId === undefined ? "" : String(trip.directionId), stops });
}

function positionFrom(message: any, into: Map<string, { lat: number; lon: number; bearing?: number }>) {
  const vehicle = message?.vehicle;
  const trip = String(vehicle?.trip?.tripId ?? ""), at = vehicle?.position;
  const lat = Number(at?.latitude), lon = Number(at?.longitude);
  if (trip && lat && lon) into.set(trip, { lat, lon, bearing: at.bearing === undefined ? undefined : Number(at.bearing) });
}
