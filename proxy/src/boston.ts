/**
 * Boston: the MBTA's subway (Red, Orange, Blue, the Green Line's branches and the Mattapan trolley),
 * its buses (the Silver Line too), commuter rail and ferries. Live times and vehicles come from its
 * GTFS-realtime feeds on cdn.mbta.com, the whole network in two files, fetched at most every
 * FEED_TTL_MS and shared by every stop, like Muni's snapshot; no key, and nothing to ration. The
 * network (lines, their stops in order and their shapes) and each stop's timetable, for trips without a
 * prediction yet (not live), come from its V3 API (api-v3.mbta.com), with a key when there is one
 * (MBTA_API_KEY: 1,000 requests a minute, 20 without): two calls a day for the network, and a stop's
 * timetable at most once an hour while people keep asking. Served under /v1/boston/...
 *
 *   GET /v1/boston/lines                       all lines; `id` as riders say it ("Red", "B" for the
 *                                              Green Line's B branch, "SL1", "39", "Fitchburg")
 *   GET /v1/boston/lines/:line                 directions ("0", "1") with stops and shapes
 *   GET /v1/boston/departures?stop=70076&line=Red&direction=1
 *   GET /v1/boston/stop?stop=70076             the lines at a stop (a list of stops: each with its `stop`)
 *   GET /v1/boston/nearby?stop=70076&direction=1   lines there and a short walk away going the same way
 *   GET /v1/boston/map, /v1/boston/stops       every line's shape, every stop with its lines
 *
 * Stop codes are the MBTA's platform or curbside stops ("70076", Park Street's northbound Red Line
 * platform), one per direction, as predictions name them.
 */

import { decodePositions } from "./ferries";
import { closestPerLine, linePairs, metersBetween, NEARBY_METERS, simplify, stopsOfLines, type NearbyLine, type Polyline } from "./geo";
import { Reader } from "./nyc";

const API = "https://api-v3.mbta.com";
const FEEDS = "https://cdn.mbta.com/realtime/";
/** How often the MBTA's realtime feeds are refreshed (they change every few seconds). */
const FEED_TTL_MS = 20_000;
const NETWORK_TTL_MS = 24 * 3600_000;
/** How long a stop's timetable is kept, and how many of its departures (from when it was asked). */
const SCHEDULE_TTL_SECONDS = 3600;
const SCHEDULE_LIMIT = 60;

export interface BostonDeps {
  cached: <T>(key: string, ttlSeconds: number, load: () => Promise<T>) => Promise<{ data: T; fetchedAt: number }>;
  apiKey?: string;
  rateLimited: () => Error;
  upstream: (status: number) => Error;
}

export interface Stop {
  code: string;
  name: string;
  lat: number;
  lon: number;
}

export interface Direction {
  id: string;
  name: string;
  destination: string;
  stops: Stop[];
  shapes: Polyline[];
}

export interface Line {
  id: string;
  name: string;
  mode: string;
  routeId: string;
  color?: string;
  textColor?: string;
  directions: Direction[];
}

export interface Visit {
  routeId: string;
  direction: string;
  destination: string;
  time: string;
  live: boolean;
  vehicle?: { lat: number; lon: number; bearing?: number };
}

const iso = (ms: number) => new Date(ms).toISOString();

export async function handleBoston(parts: string[], url: URL, deps: BostonDeps): Promise<{ body: unknown; status?: number; maxAge?: number }> {
  const lines = await loadNetwork(deps);
  const destinations = new Map(lines.map((l) => [l.routeId, l.directions.map((d) => d.destination)]));
  const liveOnly = new Set(lines.filter((l) => l.mode === "subway" || l.mode === "metro").map((l) => l.routeId));
  return serveNetwork(parts, url, lines, async (stopCodes) => {
    const [live, ...timetables] = await Promise.all([
      loadLive(),
      ...stopCodes.map((s) => deps.cached(`bos-sched:${s}`, SCHEDULE_TTL_SECONDS, () => fetchSchedule(s, deps)).catch(() => undefined)),
    ]);
    return {
      visits: stopCodes.map((s, i) => visitsAt(s, live, timetables[i]?.data ?? [], destinations, liveOnly)),
      fetchedAt: live.fetchedAt,
      ttl: FEED_TTL_MS,
    };
  });
}

/** A city's requests, served from its `lines` (see the top of this file), and departures from
 *  `departures`: each of the stops' visits, and when they were fetched and how long they keep. Boston's
 *  and Chicago's (see chicago.ts). */
export async function serveNetwork(parts: string[], url: URL, lines: Line[],
                                   departures: (stops: string[]) => Promise<{ visits: Visit[][]; fetchedAt: number; ttl: number }>)
    : Promise<{ body: unknown; status?: number; maxAge?: number }> {
  if (parts[0] === "lines" && parts.length === 1) {
    return { body: { lines: lines.map(({ id, name, mode }) => ({ id, name, mode })), fetchedAt: iso(Date.now()) }, maxAge: 3600 };
  }

  if (parts[0] === "lines" && parts.length === 2) {
    const line = lines.find((l) => l.id === decodeURIComponent(parts[1]));
    if (!line) return { body: { error: "unknown line" }, status: 404 };
    return { body: { line: line.id, directions: line.directions, fetchedAt: iso(Date.now()) }, maxAge: 3600 };
  }

  if (parts[0] === "map") {
    // One direction's shapes is enough to draw a route; the one with the most of them (branches).
    const map = lines.map(({ id, name, mode, color, textColor, directions }) => ({
      id, name, mode, color, textColor,
      shapes: [...directions].sort((a, b) => b.shapes.length - a.shapes.length)[0]?.shapes ?? [],
    }));
    return { body: { lines: map, complete: true, fetchedAt: iso(Date.now()) }, maxAge: 3600 };
  }

  if (parts[0] === "stops") {
    return { body: { stops: stopsOfLines(lines), complete: true, fetchedAt: iso(Date.now()) }, maxAge: 3600 };
  }

  const stops = new Map(lines.flatMap((l) => l.directions.flatMap((d) => d.stops.map((s) => [s.code, s] as const))));
  const stop = url.searchParams.get("stop") ?? "";

  if (parts[0] === "stop") {
    const codes = stop.split(",").filter((s) => stops.has(s));
    if (!codes.length) return { body: { error: "unknown stop" }, status: 400 };
    const found = codes.flatMap((code) => linesAt(lines, code).map((l) => (codes.length > 1 ? { ...l, stop: code } : l)));
    return { body: { stop: { code: codes[0], name: stops.get(codes[0])!.name }, lines: found } };
  }

  if (parts[0] === "nearby") {
    const here = stops.get(stop);
    if (!here) return { body: { error: "unknown stop" }, status: 400 };
    return { body: { stop: { code: stop }, lines: nearby(lines, here, url.searchParams.get("direction")) } };
  }

  if (parts[0] === "departures") {
    const code = url.searchParams.get("line");
    if (!code || !stop.split(",").every((s) => stops.has(s))) return { body: { error: "stop and line are required" }, status: 400 };
    const wanted = linePairs(code, url.searchParams.get("direction"), stop)
      .map((w) => ({ ...w, routeId: lines.find((l) => l.id === w.line)?.routeId }));
    const stopCodes = [...new Set(wanted.map((w) => w.stop))];
    const found = await departures(stopCodes);
    const now = Date.now();
    const list = found.visits
      .flatMap((visits, i) => visits.flatMap((v) => {
        const match = wanted.find((w) => w.stop === stopCodes[i] && w.routeId === v.routeId && (!w.direction || w.direction === v.direction));
        return match ? [{ line: match.line, time: v.time, live: v.live, destination: v.destination, vehicle: v.vehicle }] : [];
      }))
      .filter((d) => Date.parse(d.time) > now - 30_000)
      .sort((a, b) => Date.parse(a.time) - Date.parse(b.time))
      .slice(0, 20);
    return {
      body: {
        stop: { code: stopCodes[0], name: stops.get(stopCodes[0])?.name ?? "" },
        line: code,
        fetchedAt: iso(found.fetchedAt),
        nextRefreshAt: iso(found.fetchedAt + found.ttl + 2_000),
        stale: now - found.fetchedAt > found.ttl * 6,
        departures: list,
      },
    };
  }

  return { body: { error: "not found" }, status: 404 };
}

/** Every line and way stopping at `code` to pick people up (not where it ends). */
function linesAt(lines: Line[], code: string) {
  return lines.flatMap((l) => l.directions
    .filter((d) => d.stops.findIndex((s) => s.code === code) >= 0 && d.stops.at(-1)?.code !== code)
    .map((d) => ({ line: l.id, direction: d.id, destination: d.destination })));
}

/** The lines at `here`, then those at stops a short walk away that head off the same way as the
 *  picked `direction` does from here (within 100°), each at its closest stop. */
function nearby(lines: Line[], here: Stop, direction: string | null): NearbyLine[] {
  const leaving = (d: Direction, code: string) => {
    const i = d.stops.findIndex((s) => s.code === code);
    if (i < 0 || i + 1 >= d.stops.length) return undefined;
    const a = d.stops[i], b = d.stops[i + 1];
    return (Math.atan2((b.lon - a.lon) * Math.cos((a.lat * Math.PI) / 180), b.lat - a.lat) * 180) / Math.PI;
  };
  const ways = lines.flatMap((l) => l.directions.map((d) => ({ line: l, direction: d })));
  const ours = ways.find((w) => (!direction || w.direction.id === direction) && leaving(w.direction, here.code) !== undefined);
  const heading = ours && leaving(ours.direction, here.code);
  const found: NearbyLine[] = linesAt(lines, here.code).map((l) => ({ ...l, stop: here.code, stopName: here.name, distance: 0 }));
  const atStop = new Set(found.map((l) => l.line));
  for (const { line, direction: d } of ways) {
    if (atStop.has(line.id)) continue;
    for (const s of d.stops) {
      // At least a meter: another platform at the same station is still another stop to walk to.
      const distance = Math.max(1, Math.round(metersBetween(here, s)));
      if (s.code === here.code || distance > NEARBY_METERS) continue;
      const theirs = leaving(d, s.code);
      if (theirs === undefined || (heading !== undefined && Math.abs(((theirs - heading + 540) % 360) - 180) > 100)) continue;
      found.push({ line: line.id, direction: d.id, destination: d.destination, stop: s.code, stopName: s.name, distance, lat: s.lat, lon: s.lon });
    }
  }
  return closestPerLine(found);
}

// MARK: - Departures

export interface LiveTrip {
  route: string;
  /** "" where the feed doesn't say (WMATA's buses). */
  direction: string;
  /** Leaving each stop, in seconds since 1970; skipped stops left out. */
  stops: Map<string, number>;
}

interface Live {
  trips: Map<string, LiveTrip>;
  positions: Map<string, { lat: number; lon: number; bearing?: number }>;
  fetchedAt: number;
}

/** A timetabled departure: its trip (to tell it from a predicted one), when, and which way. */
interface Scheduled {
  trip: string;
  routeId: string;
  direction: string;
  destination: string;
  time: string;
}

/** A stop's departures: every live trip leaving it, and the timetable's trips the live feed doesn't
 *  have (yet), not live. Not for the subway (`liveOnly`): it runs to a headway rather than its
 *  timetable, and its predictions cover every train that's coming (as the MBTA's own signs show). */
function visitsAt(stop: string, live: Live, timetable: Scheduled[], destinations: Map<string, string[]>, liveOnly: Set<string>): Visit[] {
  const visits: Visit[] = [];
  for (const [id, trip] of live.trips) {
    const time = trip.stops.get(stop);
    if (time === undefined) continue;
    visits.push({
      routeId: trip.route,
      direction: trip.direction || "0",
      destination: destinations.get(trip.route)?.[Number(trip.direction || "0")] ?? "",
      time: new Date(time * 1000).toISOString(),
      live: true,
      vehicle: live.positions.get(id),
    });
  }
  for (const s of timetable) {
    if (live.trips.has(s.trip) || liveOnly.has(s.routeId)) continue;
    // A live trip by another id (an added or reassigned one) within a couple of minutes is this one.
    const at = Date.parse(s.time);
    if (visits.some((v) => v.live && v.routeId === s.routeId && v.direction === s.direction && Math.abs(Date.parse(v.time) - at) < 120_000)) continue;
    visits.push({ routeId: s.routeId, direction: s.direction, destination: s.destination, time: s.time, live: false });
  }
  return visits.sort((a, b) => Date.parse(a.time) - Date.parse(b.time));
}

let live: Promise<Live> | undefined;

/** The MBTA's trip updates and vehicle positions, at most every FEED_TTL_MS; the last copy on a hiccup. */
async function loadLive(): Promise<Live> {
  const cached = await live?.catch(() => undefined);
  if (cached && Date.now() - cached.fetchedAt < FEED_TTL_MS) return cached;
  const next = (async () => {
    const get = async (name: string) => {
      const response = await fetch(FEEDS + name);
      if (!response.ok) throw new Error(`MBTA ${name}: ${response.status}`);
      return new Uint8Array(await response.arrayBuffer());
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

/** TripUpdate entities → each trip's route, direction and when it leaves each stop. FeedEntity 3:
 *  TripUpdate (1 trip: 1 trip_id, 4 schedule_relationship, 5 route_id, 6 direction_id; 2
 *  stop_time_update: 2 arrival / 3 departure (2 time), 4 stop_id, 5 schedule_relationship).
 *  `arrivals`: a feed that gives only when trips arrive (WMATA's, but where they start) leaves then,
 *  but at the last stop it has. */
export function decodeTrips(bytes: Uint8Array, arrivals = false): Map<string, LiveTrip> {
  const trips = new Map<string, LiveTrip>();
  for (const entity of new Reader(bytes).fields()) {
    if (entity.field !== 2 || !entity.sub) continue;
    for (const part of entity.sub.fields()) {
      if (part.field !== 3 || !part.sub) continue;
      let id = "", route = "", direction = "", canceled = false;
      const stops = new Map<string, number>();
      let last = "";
      for (const f of part.sub.fields()) {
        if (f.field === 1 && f.sub) {
          for (const t of f.sub.fields()) {
            if (t.field === 1 && t.sub) id = t.sub.string();
            if (t.field === 5 && t.sub) route = t.sub.string();
            if (t.field === 6) direction = String(t.value);
            if (t.field === 4 && t.value === 3) canceled = true;
          }
        }
        if (f.field === 2 && f.sub) {
          let stop = "", arrival = 0, departure = 0, skipped = false;
          for (const u of f.sub.fields()) {
            if (u.field === 4 && u.sub) stop = u.sub.string();
            if (u.field === 5 && u.value === 1) skipped = true;
            if ((u.field === 2 || u.field === 3) && u.sub) {
              for (const e of u.sub.fields()) if (e.field === 2) u.field === 2 ? (arrival = e.value) : (departure = e.value);
            }
          }
          // Only where it leaves from: an arrival alone is the end of the line, nobody gets on.
          if (stop && (departure || (arrivals && arrival)) && !skipped) {
            stops.set(stop, departure || arrival);
            last = departure ? "" : stop;
          }
        }
      }
      if (last) stops.delete(last);
      if (id && route && !canceled && stops.size) trips.set(id, { route, direction, stops });
    }
  }
  return trips;
}

/** A stop's timetable for the rest of today, from now; kept an hour, for trips with no prediction yet. */
async function fetchSchedule(stop: string, deps: BostonDeps): Promise<Scheduled[]> {
  const local = new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" })
    .formatToParts(Date.now());
  const part = (type: string) => local.find((p) => p.type === type)?.value ?? "";
  const body = await call(`/schedules?filter[stop]=${encodeURIComponent(stop)}&filter[date]=${part("year")}-${part("month")}-${part("day")}`
    + `&filter[min_time]=${part("hour")}:${part("minute")}&sort=departure_time&page[limit]=${SCHEDULE_LIMIT}`
    + "&include=trip&fields[schedule]=departure_time,direction_id,pickup_type&fields[trip]=headsign", deps);
  const headsigns = new Map((body.included ?? []).map((i: any) => [i.id, i.attributes?.headsign ?? ""]));
  // Pickup type 1: nobody gets on here.
  return (body.data ?? []).filter((s: any) => s.attributes.departure_time && s.attributes.pickup_type !== 1).map((s: any) => ({
    trip: s.relationships.trip.data.id,
    routeId: s.relationships.route.data.id,
    direction: String(s.attributes.direction_id),
    destination: (headsigns.get(s.relationships.trip.data.id) as string) ?? "",
    time: new Date(s.attributes.departure_time).toISOString(),
  }));
}

async function call(path: string, deps: BostonDeps): Promise<any> {
  const response = await fetch(API + path, { headers: deps.apiKey ? { "x-api-key": deps.apiKey } : {} });
  if (response.status === 429) throw deps.rateLimited();
  if (!response.ok) throw deps.upstream(response.status);
  return response.json();
}

// MARK: - The network

let network: { value: Promise<Line[]>; at: number } | undefined;

function loadNetwork(deps: BostonDeps): Promise<Line[]> {
  if (network && Date.now() - network.at < NETWORK_TTL_MS) return network.value;
  const previous = network;
  const value = buildNetwork(deps).catch((error) => {
    // Keep yesterday's on a hiccup; try again in a few minutes.
    if (previous) {
      network = { value: previous.value, at: Date.now() - NETWORK_TTL_MS + 300_000 };
      return previous.value;
    }
    network = undefined;
    throw error;
  });
  network = { value, at: Date.now() };
  return value;
}

async function buildNetwork(deps: BostonDeps): Promise<Line[]> {
  const routes: any[] = (await call("/routes?filter[type]=0,1,2,3,4"
    + "&fields[route]=short_name,long_name,type,color,text_color,direction_destinations,sort_order", deps)).data;
  const patterns = await call(`/route_patterns?filter[route]=${routes.map((r) => r.id).join(",")}`
    + "&include=representative_trip.shape,representative_trip.stops"
    + "&fields[route_pattern]=typicality,direction_id,sort_order&fields[stop]=name,latitude,longitude&fields[trip]=headsign&fields[shape]=polyline", deps);
  const included = new Map((patterns.included ?? []).map((i: any) => [`${i.type}:${i.id}`, i]));
  const byRoute = new Map<string, any[]>();
  for (const p of patterns.data) {
    const route = p.relationships.route.data.id;
    byRoute.set(route, [...(byRoute.get(route) ?? []), p]);
  }

  const lines: Line[] = [];
  for (const route of routes.sort((a, b) => a.attributes.sort_order - b.attributes.sort_order)) {
    const a = route.attributes;
    const directions: Direction[] = [];
    for (const direction of [0, 1]) {
      const all = (byRoute.get(route.id) ?? []).filter((p) => p.attributes.direction_id === direction);
      // The typical patterns (both Red Line branches, say); a route with none, its likeliest.
      const best = Math.min(...all.map((p) => p.attributes.typicality));
      const typical = all.filter((p) => p.attributes.typicality === best).sort((x, y) => x.attributes.sort_order - y.attributes.sort_order);
      if (!typical.length) continue;
      const trips = typical.map((p) => included.get(`trip:${p.relationships.representative_trip.data.id}`) as any).filter(Boolean);
      const stopRuns = trips.map((t) => (t.relationships.stops?.data ?? []).map((s: any) => s.id as string));
      const stops = mergeRuns(stopRuns).flatMap((code) => {
        const s = included.get(`stop:${code}`) as any;
        return s ? [{ code, name: s.attributes.name, lat: s.attributes.latitude, lon: s.attributes.longitude }] : [];
      });
      const shapes = trips.flatMap((t) => {
        const shape = included.get(`shape:${t.relationships.shape?.data?.id}`) as any;
        return shape?.attributes?.polyline ? [simplify(decodePolyline(shape.attributes.polyline))] : [];
      });
      const destination = a.direction_destinations?.[direction] ?? stops.at(-1)?.name ?? "";
      directions.push({ id: String(direction), name: destination, destination, stops, shapes });
    }
    if (!directions.length) continue;
    lines.push({ id: lineId(route), name: lineName(route), mode: MODES[a.type] ?? "bus", routeId: route.id,
                 color: a.color ? `#${a.color}` : undefined, textColor: a.text_color ? `#${a.text_color}` : undefined, directions });
  }
  // Ids as riders say them can clash (in principle); the second one keeps the MBTA's.
  const seen = new Set<string>();
  for (const line of lines) {
    if (seen.has(line.id)) line.id = line.routeId;
    seen.add(line.id);
  }
  return lines;
}

const MODES: Record<number, string> = { 0: "metro", 1: "subway", 2: "rail", 3: "bus", 4: "ferry" };

/** As riders say it: "Red", "B" for the Green Line's B branch, "SL1", "39", "Fitchburg", "Hingham". */
function lineId(route: any): string {
  const a = route.attributes;
  if (route.id.startsWith("Green-")) return route.id.slice(6);
  if (a.type === 0 || a.type === 1) return route.id;
  if (a.type === 2) return a.long_name.replace(/ Line$/, "");
  if (a.type === 4) return a.long_name.replace(/ Ferry$/, "");
  return a.short_name || route.id;
}

function lineName(route: any): string {
  const a = route.attributes;
  return (a.long_name || a.short_name || route.id).replace(/ - /g, " – ");
}

/** The longest run of stops, with stops only other runs have placed after the one before them. */
function mergeRuns(runs: string[][]): string[] {
  const sorted = [...runs].sort((a, b) => b.length - a.length);
  const merged = [...(sorted[0] ?? [])];
  for (const run of sorted.slice(1)) {
    run.forEach((stop, i) => {
      if (merged.includes(stop)) return;
      const before = i > 0 ? merged.indexOf(run[i - 1]) : -1;
      merged.splice(before + 1, 0, stop);
    });
  }
  return merged;
}

/** Google's encoded polyline format, as the MBTA's shapes come. */
function decodePolyline(encoded: string): Polyline {
  const points: Polyline = [];
  let index = 0, lat = 0, lon = 0;
  const next = () => {
    let result = 0, shift = 0, byte: number;
    do {
      byte = encoded.charCodeAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    return result & 1 ? ~(result >> 1) : result >> 1;
  };
  while (index < encoded.length) {
    lat += next();
    lon += next();
    points.push([lat / 1e5, lon / 1e5]);
  }
  return points;
}
