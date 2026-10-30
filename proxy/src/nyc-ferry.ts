/**
 * New York's ferries: NYC Ferry and NY Waterway (across the Hudson to New Jersey), with live times and
 * boat positions from their GTFS-realtime feeds while boats are running, and the Staten Island Ferry,
 * from its published schedule (it has no live feed). All come from the operators' static GTFS, fetched
 * at most once a day; a departure the live feed doesn't mention is the scheduled one (and says so: not
 * live). Served under /v1/nyc/... next to the subway and buses (see nyc.ts). Stop ids carry the
 * operator: "NYCF_4", "SIF_stgeorge", "NYW_4".
 *
 * Not Seastreak (to the Highlands and Sandy Hook): its GTFS has each return trip as a jumbled copy of
 * the trip out, at the same times, which would list boats that don't run.
 */

import { decodeFeed, Reader } from "./nyc";
import { hexColor, linePairs, parseCSV, readZipEntry, simplify, stopsOfLines, type Polyline } from "./geo";

interface Operator {
  /** Prefix of this operator's stop and trip ids. */
  key: string;
  gtfs: string;
  /** The rider-facing line id for a route. */
  lineId: (route: Record<string, string>) => string;
  /** The route's name, where its own wants spelling out. */
  name?: (route: Record<string, string>) => string;
  tripUpdates?: string;
  vehiclePositions?: string;
}

const OPERATORS: Operator[] = [
  {
    key: "NYCF",
    gtfs: "http://nycferry.connexionz.net/rtt/public/resource/gtfs.zip",
    // NYC Ferry's own route codes, as on its maps: "ER" East River, "SB" South Brooklyn.
    lineId: (route) => route.route_short_name || route.route_id,
    tripUpdates: "http://nycferry.connexionz.net/rtt/public/utility/gtfsrealtime.aspx/tripupdate",
    vehiclePositions: "http://nycferry.connexionz.net/rtt/public/utility/gtfsrealtime.aspx/vehicleposition",
  },
  {
    key: "SIF",
    gtfs: "https://www.nyc.gov/html/dot/downloads/misc/siferry-gtfs.zip",
    lineId: () => "SI Ferry",
  },
  {
    // The same Connexionz system as NYC Ferry's.
    key: "NYW",
    gtfs: "http://nywaterway.connexionz.net/rtt/public/resource/gtfs.zip",
    // Its route numbers ("15" Hoboken – Pier 11), as on its timetables.
    lineId: (route) => route.route_short_name || route.route_id,
    // Its names are cut to fit its timetables: "Pt Imp & H14 - BPT & P11".
    name: (route) => [
      [/\bPt Imp\b/g, "Port Imperial"], [/\bH14\b/g, "Hoboken 14th St"], [/\bH\/NJT\b/g, "Hoboken/NJT"],
      [/\bBPT\b/g, "Brookfield Place"], [/\bP11\b/g, "Pier 11"], [/\bLin Har\b/g, "Lincoln Harbor"],
      [/\bLib Har\b/g, "Liberty Harbor"], [/\bPaulus Hk\b/g, "Paulus Hook"], [/ - /g, " – "],
    ].reduce((name, [from, to]) => name.replace(from as RegExp, to as string), route.route_long_name),
    tripUpdates: "http://nywaterway.connexionz.net/rtt/public/utility/gtfsrealtime.aspx/tripupdate",
    vehiclePositions: "http://nywaterway.connexionz.net/rtt/public/utility/gtfsrealtime.aspx/vehicleposition",
  },
];

export const FERRY_STOP = /^(NYCF|SIF|NYW)_\w+$/;

const NETWORK_TTL_MS = 24 * 3600_000;
const FEED_TTL_MS = 30_000;
/** How far ahead scheduled departures are listed: at night, as far as the first boats in the morning. */
const HORIZON_MS = 12 * 3600_000;

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
  mode: "ferry";
  color?: string;
  textColor?: string;
  directions: Direction[];
}

interface ScheduledTrip {
  /** The operator's trip id, unprefixed, as the live feed names it. */
  id: string;
  operator: string;
  line: string;
  direction: string;
  service: string;
  /** Seconds after the service day's midnight, per stop code. */
  times: Map<string, number>;
  /** Where it ends: a boat arriving there isn't one to catch. */
  last: string;
}

/** Which services run on a day ("20261028"), per operator. */
interface Calendar {
  weekly: Map<string, { days: boolean[]; start: string; end: string }>;
  added: Map<string, Set<string>>;
  removed: Map<string, Set<string>>;
}

interface Network {
  lines: Line[];
  trips: ScheduledTrip[];
  calendars: Map<string, Calendar>;
}

// MARK: - Requests

export async function handleFerry(parts: string[], url: URL): Promise<{ body: unknown; status?: number; maxAge?: number }> {
  const network = await loadNetwork();

  if (parts[0] === "lines" && parts.length === 2) {
    const line = network.lines.find((l) => l.id === decodeURIComponent(parts[1]));
    if (!line) return { body: { error: "unknown line" }, status: 404 };
    return { body: { line: line.id, directions: line.directions, fetchedAt: new Date().toISOString() }, maxAge: 3600 };
  }

  const stop = url.searchParams.get("stop") ?? "";
  const stops = new Map(network.lines.flatMap((l) => l.directions.flatMap((d) => d.stops.map((s) => [s.code, s] as const))));

  if (parts[0] === "stop" || parts[0] === "nearby") {
    // Ferry landings are far apart; the boats at this one are all there is nearby.
    if (!stops.has(stop)) return { body: { error: "unknown stop" }, status: 400 };
    const lines = linesAt(network, stop)
      .map((l) => (parts[0] === "nearby" ? { ...l, stop, stopName: stops.get(stop)!.name, distance: 0 } : l));
    return { body: { stop: { code: stop, name: stops.get(stop)!.name }, lines } };
  }

  if (parts[0] === "departures") {
    const code = url.searchParams.get("line");
    if (!code || !stop.split(",").every((s) => stops.has(s))) return { body: { error: "stop and line are required" }, status: 400 };
    const wanted = linePairs(code, url.searchParams.get("direction"), stop);
    const live = await loadLive();
    const now = Date.now();
    const departures = scheduled(network, now)
      .flatMap(({ trip, midnight }) => {
        const match = wanted.find((w) => w.line === trip.line && w.stop !== trip.last && trip.times.has(w.stop)
          && (!w.direction || w.direction === trip.direction));
        if (!match) return [];
        const destination = network.lines.find((l) => l.id === trip.line)?.directions.find((d) => d.id === trip.direction)?.destination ?? "";
        // The live feed's time for this boat, where it has one.
        const update = live.trips.get(`${trip.operator}:${trip.id}`)?.stops.find((s) => `${trip.operator}_${s.stop}` === match.stop);
        const vehicle = live.positions.get(`${trip.operator}:${trip.id}`);
        const time = update?.time ? update.time * 1000 : midnight + trip.times.get(match.stop)! * 1000;
        return [{ line: trip.line, time: new Date(time).toISOString(), live: Boolean(update?.time), destination, vehicle }];
      })
      .filter((d) => Date.parse(d.time) > now - 30_000)
      .sort((a, b) => Date.parse(a.time) - Date.parse(b.time))
      .slice(0, 20);
    const first = wanted[0]?.stop ?? stop;
    return {
      body: {
        stop: { code: first, name: stops.get(first)?.name ?? "" },
        line: code,
        fetchedAt: new Date(live.fetchedAt).toISOString(),
        nextRefreshAt: new Date(live.fetchedAt + FEED_TTL_MS + 2_000).toISOString(),
        stale: false,
        departures,
      },
    };
  }

  return { body: { error: "not found" }, status: 404 };
}

/** The ferry lines as the NYC line list wants them. */
export async function ferryLines() {
  return (await loadNetwork()).lines.map(({ id, name, mode }) => ({ id, name, mode }));
}

/** The ferry lines for the NYC line map: one direction's shapes is enough to draw a route. */
export async function ferryMap() {
  return (await loadNetwork()).lines.map(({ id, name, mode, color, textColor, directions }) => ({
    id, name, mode, color, textColor,
    shapes: [...directions].sort((a, b) => b.shapes.length - a.shapes.length)[0]?.shapes ?? [],
  }));
}

/** Every ferry landing, with its lines, for the map's stop dots. */
export async function ferryStops() {
  return stopsOfLines((await loadNetwork()).lines);
}

export async function ferryLineIds() {
  return new Set((await loadNetwork()).lines.map((l) => l.id));
}

function linesAt(network: Network, stop: string) {
  return network.lines.flatMap((l) => l.directions
    .filter((d) => d.stops.some((s) => s.code === stop))
    .map((d) => ({ line: l.id, direction: d.id, destination: d.destination })));
}

/** Every trip running yesterday (after midnight) or today in New York, with its service day's midnight. */
function scheduled(network: Network, now: number) {
  const found: { trip: ScheduledTrip; midnight: number }[] = [];
  for (const day of [-1, 0]) {
    const date = nycDate(now + day * 86400_000);
    const midnight = nycMidnight(date);
    const running = new Map([...network.calendars].map(([operator, calendar]) => [operator, servicesOn(calendar, date)]));
    for (const trip of network.trips) {
      if (!running.get(trip.operator)?.has(trip.service)) continue;
      const times = [...trip.times.values()];
      if (midnight + Math.max(...times) * 1000 < now - 60_000 || midnight + Math.min(...times) * 1000 > now + HORIZON_MS) continue;
      found.push({ trip, midnight });
    }
  }
  return found;
}

function servicesOn(calendar: Calendar, date: string): Set<string> {
  const weekday = (new Date(`${date.slice(0, 4)}-${date.slice(4, 6)}-${date.slice(6)}T12:00:00Z`).getUTCDay() + 6) % 7;
  const services = new Set<string>();
  for (const [id, week] of calendar.weekly) {
    if (week.days[weekday] && week.start <= date && date <= week.end) services.add(id);
  }
  for (const id of calendar.added.get(date) ?? []) services.add(id);
  for (const id of calendar.removed.get(date) ?? []) services.delete(id);
  return services;
}

/** "20261028": the date in New York at `ms`. */
function nycDate(ms: number): string {
  const parts = new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit" }).format(ms);
  return parts.replaceAll("-", "");
}

/** Midnight in New York at the start of `date` ("20261028"), as epoch milliseconds. */
function nycMidnight(date: string): number {
  const [y, m, d] = [Number(date.slice(0, 4)), Number(date.slice(4, 6)), Number(date.slice(6))];
  const noon = Date.UTC(y, m - 1, d, 12);
  // "GMT-4" in summer, "GMT-5" in winter; noon's offset is the day's (clocks change at 2 am).
  const offset = new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York", timeZoneName: "shortOffset" })
    .formatToParts(noon).find((p) => p.type === "timeZoneName")?.value ?? "GMT-5";
  const hours = Number(offset.replace("GMT", "") || 0);
  return Date.UTC(y, m - 1, d) - hours * 3600_000;
}

// MARK: - The network, from the operators' GTFS

let network: { value: Promise<Network>; at: number } | undefined;

function loadNetwork(): Promise<Network> {
  if (network && Date.now() - network.at < NETWORK_TTL_MS) return network.value;
  const previous = network;
  const value = buildNetwork().catch((error) => {
    // Keep serving yesterday's network on a hiccup; try again in a few minutes.
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

async function buildNetwork(): Promise<Network> {
  const built = await Promise.all(OPERATORS.map(readOperator));
  return {
    lines: built.flatMap((b) => b.lines),
    trips: built.flatMap((b) => b.trips),
    calendars: new Map(built.map((b, i) => [OPERATORS[i].key, b.calendar])),
  };
}

async function readOperator(operator: Operator) {
  // nyc.gov turns away requests without a browser-like user agent.
  const response = await fetch(operator.gtfs, { headers: { "User-Agent": "Mozilla/5.0 (37 Shades of Late; https://37shadesoflate.com)" } });
  if (!response.ok) throw new Error(`${operator.key} GTFS: ${response.status}`);
  const zip = await response.arrayBuffer();
  const read = async (name: string) => parseCSV((await readZipEntry(zip, name)) ?? "");
  const [routes, stopRows, tripRows, stopTimes, shapeRows, calendarRows, calendarDates] = await Promise.all(
    ["routes.txt", "stops.txt", "trips.txt", "stop_times.txt", "shapes.txt", "calendar.txt", "calendar_dates.txt"].map(read));

  const code = (stopId: string) => `${operator.key}_${stopId}`;
  // "St. George Ferry Terminal" → "St. George", "Wall St./Pier 11" stays.
  const stopName = (name: string) => name.replace(/ Ferry Terminal$/, "").trim();
  const stops = new Map(stopRows.map((s) => [s.stop_id, { code: code(s.stop_id), name: stopName(s.stop_name), lat: Number(s.stop_lat), lon: Number(s.stop_lon) }]));

  const seconds = (time: string) => {
    const [h, m, s] = time.split(":").map(Number);
    return h * 3600 + m * 60 + (s || 0);
  };
  const timesByTrip = new Map<string, { sequence: number; stop: string; time: number }[]>();
  for (const st of stopTimes) {
    const list = timesByTrip.get(st.trip_id) ?? [];
    list.push({ sequence: Number(st.stop_sequence), stop: st.stop_id, time: seconds(st.departure_time || st.arrival_time) });
    timesByTrip.set(st.trip_id, list);
  }
  for (const list of timesByTrip.values()) list.sort((a, b) => a.sequence - b.sequence);

  const shapes = new Map<string, [number, number, number][]>();
  for (const p of shapeRows) {
    const list = shapes.get(p.shape_id) ?? [];
    list.push([Number(p.shape_pt_sequence), Number(p.shape_pt_lat), Number(p.shape_pt_lon)]);
    shapes.set(p.shape_id, list);
  }

  const lines: Line[] = [];
  const trips: ScheduledTrip[] = [];
  // Boats only: NYC Ferry also runs shuttle buses around the Rockaways (route type 3).
  for (const route of routes.filter((r) => r.route_type === "4")) {
    const lineId = operator.lineId(route);
    const routeTrips = tripRows.filter((t) => t.route_id === route.route_id && timesByTrip.get(t.trip_id)?.length);
    // A direction is GTFS's direction_id where there is one, else where the boat ends up.
    const directionOf = (t: Record<string, string>) => t.direction_id || timesByTrip.get(t.trip_id)!.at(-1)!.stop;
    const byDirection = new Map<string, Record<string, string>[]>();
    for (const t of routeTrips) byDirection.set(directionOf(t), [...(byDirection.get(directionOf(t)) ?? []), t]);

    const directions: Direction[] = [...byDirection].sort(([a], [b]) => a.localeCompare(b)).map(([id, list]) => {
      const patterns = list.map((t) => timesByTrip.get(t.trip_id)!.map((s) => s.stop));
      const order = mergePatterns(patterns);
      // Where most boats this way end up.
      const ends = new Map<string, number>();
      for (const p of patterns) ends.set(p.at(-1)!, (ends.get(p.at(-1)!) ?? 0) + 1);
      const destination = stops.get([...ends].sort((a, b) => b[1] - a[1])[0][0])?.name ?? "";
      const shapeCounts = new Map<string, number>();
      for (const t of list) if (t.shape_id) shapeCounts.set(t.shape_id, (shapeCounts.get(t.shape_id) ?? 0) + 1);
      const drawn = [...shapeCounts].sort((a, b) => b[1] - a[1]).slice(0, 3).flatMap(([shapeId]) => {
        const points = (shapes.get(shapeId) ?? []).sort((a, b) => a[0] - b[0]).map(([, lat, lon]) => [lat, lon] as [number, number]);
        return points.length > 1 ? [simplify(points)] : [];
      });
      return {
        id, name: destination, destination,
        stops: order.flatMap((s) => (stops.get(s) ? [stops.get(s)!] : [])),
        // Without a shape, straight across the water from landing to landing.
        shapes: drawn.length ? drawn : [order.flatMap((s) => (stops.get(s) ? [[stops.get(s)!.lat, stops.get(s)!.lon] as [number, number]] : []))],
      };
    });

    lines.push({
      id: lineId,
      name: operator.name?.(route) ?? (route.route_long_name || lineId),
      mode: "ferry",
      color: hexColor(route.route_color),
      textColor: hexColor(route.route_text_color),
      directions,
    });
    for (const t of routeTrips) {
      trips.push({
        id: t.trip_id, operator: operator.key, line: lineId, direction: directionOf(t), service: t.service_id,
        times: new Map(timesByTrip.get(t.trip_id)!.map((s) => [code(s.stop), s.time])),
        last: code(timesByTrip.get(t.trip_id)!.at(-1)!.stop),
      });
    }
  }

  const calendar: Calendar = { weekly: new Map(), added: new Map(), removed: new Map() };
  const weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"];
  for (const c of calendarRows) {
    calendar.weekly.set(c.service_id, { days: weekdays.map((d) => c[d] === "1"), start: c.start_date, end: c.end_date });
  }
  for (const c of calendarDates) {
    const map = c.exception_type === "1" ? calendar.added : calendar.removed;
    map.set(c.date, (map.get(c.date) ?? new Set()).add(c.service_id));
  }
  return { lines, trips, calendar };
}

/** The longest stop order (the most common of those), with stops only shorter runs make placed after the
 *  one before them. */
function mergePatterns(patterns: string[][]): string[] {
  const counts = new Map<string, { pattern: string[]; count: number }>();
  for (const p of patterns) {
    const key = p.join(">");
    counts.set(key, { pattern: p, count: (counts.get(key)?.count ?? 0) + 1 });
  }
  const ranked = [...counts.values()].sort((a, b) => b.pattern.length - a.pattern.length || b.count - a.count);
  const merged = [...(ranked[0]?.pattern ?? [])];
  for (const { pattern } of ranked.slice(1)) {
    pattern.forEach((stop, i) => {
      if (merged.includes(stop)) return;
      const before = i > 0 ? merged.indexOf(pattern[i - 1]) : -1;
      merged.splice(before + 1, 0, stop);
    });
  }
  return merged;
}

// MARK: - The live feeds (NYC Ferry's and NY Waterway's)

interface Live {
  /** By operator and trip: "NYW:12345". */
  trips: Map<string, { stops: { stop: string; time: number }[] }>;
  positions: Map<string, { lat: number; lon: number; bearing?: number }>;
  fetchedAt: number;
}

let live: Promise<Live> | undefined;

/** The operators' trip updates and boat positions, at most every FEED_TTL_MS; an operator's are empty
 *  when they can't be had. */
async function loadLive(): Promise<Live> {
  const cached = await live?.catch(() => undefined);
  if (cached && Date.now() - cached.fetchedAt < FEED_TTL_MS) return cached;
  live = (async () => {
    const get = (feed: string) => fetch(feed).then(async (r) => (r.ok ? new Uint8Array(await r.arrayBuffer()) : undefined)).catch(() => undefined);
    const feeds = await Promise.all(OPERATORS.filter((o) => o.tripUpdates).map(async (operator) => {
      const [updates, positions] = await Promise.all([get(operator.tripUpdates!), get(operator.vehiclePositions!)]);
      const key = (trip: string) => `${operator.key}:${trip}`;
      return {
        trips: (updates ? decodeFeed(updates) : []).flatMap((t) => (t.id ? [[key(t.id), t] as const] : [])),
        positions: [...(positions ? decodePositions(positions) : new Map())].map(([trip, p]) => [key(trip), p] as const),
      };
    }));
    return {
      trips: new Map(feeds.flatMap((f) => f.trips)),
      positions: new Map(feeds.flatMap((f) => f.positions)),
      fetchedAt: Date.now(),
    };
  })();
  return live;
}

/** VehiclePosition entities → where each trip's boat is: 1 trip, 2 position (1 lat, 2 lon, 3 bearing). */
function decodePositions(bytes: Uint8Array) {
  const found = new Map<string, { lat: number; lon: number; bearing?: number }>();
  for (const entity of new Reader(bytes).fields()) {
    if (entity.field !== 2 || !entity.sub) continue;
    for (const part of entity.sub.fields()) {
      if (part.field !== 4 || !part.sub) continue;
      let trip = "";
      let position: { lat: number; lon: number; bearing?: number } | undefined;
      for (const f of part.sub.fields()) {
        if (f.field === 1 && f.sub) {
          for (const t of f.sub.fields()) if (t.field === 1 && t.sub) trip = t.sub.string();
        }
        if (f.field === 2 && f.sub) {
          const p: { lat: number; lon: number; bearing?: number } = { lat: 0, lon: 0 };
          for (const g of f.sub.fields()) {
            if (g.field === 1) p.lat = g.value;
            if (g.field === 2) p.lon = g.value;
            if (g.field === 3) p.bearing = g.value;
          }
          if (p.lat && p.lon) position = p;
        }
      }
      if (trip && position) found.set(trip, position);
    }
  }
  return found;
}
