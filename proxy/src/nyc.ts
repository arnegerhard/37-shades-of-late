/**
 * New York City subway (and the Staten Island Railway), from the MTA's GTFS-realtime feeds, and
 * PATH, from the Port Authority's RidePATH feed; neither needs a key. The network itself (lines,
 * stops in order, track shapes) is bundled as nyc-subway.json, built from the static GTFS by
 * scripts/nyc-subway.py. Each feed covers a group of lines and is fetched at most every FEED_TTL_MS
 * while people ask for those lines.
 *
 *   GET /v1/nyc/lines                          all lines, `id` is the rider-facing name ("A", "7", "S 42 St")
 *   GET /v1/nyc/lines/:line                    directions ("N"/"S"; PATH's "Y" to New York and "J" to
 *                                              New Jersey) with stops and track shapes
 *   GET /v1/nyc/departures?stop=G29S&line=G&direction=S
 *   GET /v1/nyc/stop?stop=G29S                 lines at the platform
 *   GET /v1/nyc/nearby?stop=G29S               lines at the platform, at the station's other platforms
 *                                              and at transfer stations, the same way (N or S)
 *   GET /v1/nyc/map                            every line's track shape, for picking a line on a map
 *
 * Subway trains have no GPS; a train on the map is drawn at the station it's at, or partway to
 * the one it's heading for.
 */

import network from "./nyc-subway.json";
import { NYC_BUS } from "./nyc-bus";
import { handleOBA, type SeattleDeps } from "./seattle";
import { closestPerLine, linePairs, metersBetween, NEARBY_METERS, type NearbyLine, type Polyline } from "./geo";

const FEEDS = "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2F";
/** What the RidePATH app shows: per station and direction, the next trains with seconds to arrival. */
const PATH_FEED = "https://www.panynj.gov/bin/portauthority/ridepath.json";
/** The MTA refreshes its feeds about every 30 seconds. */
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
  routeId: string;
  name: string;
  mode: string;
  color?: string | null;
  textColor?: string | null;
  feed: string;
  directions: Direction[];
}

const LINES = network.lines as Line[];
const TRANSFERS = network.transfers as Record<string, string[]>;
/** The feeds call the diamond express runs by their own route ids. */
const ROUTES = new Map<string, Line>([
  ...LINES.map((l) => [l.routeId, l] as const),
  ["6X", LINES.find((l) => l.routeId === "6")!],
  ["7X", LINES.find((l) => l.routeId === "7")!],
  ["FX", LINES.find((l) => l.routeId === "F")!],
]);
/** Every platform (directional stop id, "G29S") and the station it's part of ("G29"). */
const STOPS = new Map<string, Stop>(LINES.flatMap((l) => l.directions.flatMap((d) => d.stops.map((s) => [s.code, s] as const))));

const station = (stop: string) => stop.slice(0, -1);

/**
 * The subway and PATH from here, the buses from MTA Bus Time (nyc-bus.ts) when there's a key. Lines
 * and the map list both; a stop's requests go to whichever its id belongs to ("MTA_…" is a bus stop).
 */
export async function handleNYC(parts: string[], url: URL, bus?: SeattleDeps): Promise<{ body: unknown; status?: number; maxAge?: number }> {
  const buses = (path: string[]) => handleOBA(path, url, bus!, NYC_BUS);
  if (!bus) return handleRail(parts, url);

  if (parts[0] === "lines" && parts.length === 1) {
    const [rail, road] = await Promise.all([handleRail(parts, url), buses(parts).catch(() => undefined)]);
    const lines = [...(rail.body as any).lines, ...((road?.body as any)?.lines ?? [])];
    // Without the buses (Bus Time down), don't let the shorter list be cached for long.
    return { body: { lines, fetchedAt: (rail.body as any).fetchedAt }, maxAge: road && !("status" in road) ? 3600 : 0 };
  }

  if (parts[0] === "lines" && parts.length === 2) {
    const id = decodeURIComponent(parts[1]);
    return LINES.some((l) => l.id === id) ? handleRail(parts, url) : buses(parts);
  }

  if (parts[0] === "map") {
    // The bus map fills in over a few requests (see fetchMap in seattle.ts); until then it says so.
    const [rail, road] = await Promise.all([handleRail(parts, url), buses(parts).catch(() => undefined)]);
    const roadBody = road?.body as any;
    const lines = [...(rail.body as any).lines, ...(roadBody?.lines ?? [])];
    const complete = Boolean(roadBody?.complete);
    return { body: { lines, complete, fetchedAt: (rail.body as any).fetchedAt }, maxAge: complete ? 3600 : 0 };
  }

  const stop = url.searchParams.get("stop") ?? "";
  return NYC_BUS.stopPattern.test(stop.split(",")[0]) ? buses(parts) : handleRail(parts, url);
}

async function handleRail(parts: string[], url: URL) {
  if (parts[0] === "lines" && parts.length === 1) {
    return { body: { lines: LINES.map(({ id, name, mode }) => ({ id, name, mode })), fetchedAt: iso(Date.now()) }, maxAge: 3600 };
  }

  if (parts[0] === "lines" && parts.length === 2) {
    const line = LINES.find((l) => l.id === decodeURIComponent(parts[1]));
    if (!line) return { body: { error: "unknown line" }, status: 404 };
    return { body: { line: line.id, directions: line.directions, fetchedAt: iso(Date.now()) }, maxAge: 3600 };
  }

  if (parts[0] === "map") {
    // One direction is enough to draw the line; take the one with more branches drawn.
    const lines = LINES.map(({ id, name, mode, color, textColor, directions }) => ({
      id, name, mode, color: color ?? undefined, textColor: textColor ?? undefined,
      shapes: [...directions].sort((a, b) => b.shapes.length - a.shapes.length)[0]?.shapes ?? [],
    }));
    return { body: { lines, complete: true, fetchedAt: iso(Date.now()) }, maxAge: 3600 };
  }

  const stop = url.searchParams.get("stop") ?? "";

  if (parts[0] === "stop") {
    if (!STOPS.has(stop)) return { body: { error: "unknown stop" }, status: 400 };
    return { body: { stop: { code: stop, name: STOPS.get(stop)!.name }, lines: linesAt(stop) } };
  }

  if (parts[0] === "nearby") {
    const here = STOPS.get(stop);
    if (!here) return { body: { error: "unknown stop" }, status: 400 };
    const way = stop.slice(-1);
    const found: NearbyLine[] = [];
    // The station's other platforms that way, then those of stations you can change to or walk to.
    const stations = new Set([station(stop), ...(TRANSFERS[station(stop)] ?? [])]);
    for (const [code, other] of STOPS) {
      if (!code.endsWith(way)) continue;
      const distance = station(code) === station(stop) ? 0 : Math.round(metersBetween(here, other));
      if (!stations.has(station(code)) && distance > NEARBY_METERS) continue;
      for (const l of linesAt(code)) {
        found.push({ ...l, stop: code, stopName: other.name, distance, lat: other.lat, lon: other.lon });
      }
    }
    return { body: { stop: { code: stop }, lines: closestPerLine(found) } };
  }

  if (parts[0] === "departures") {
    const code = url.searchParams.get("line");
    // `stop` may be a list too, a stop per line, for lines caught at a nearby platform.
    if (!code || !stop.split(",").every((s) => STOPS.has(s))) return { body: { error: "stop and line are required" }, status: 400 };
    const wanted = linePairs(code, url.searchParams.get("direction"), stop)
      .map((w) => ({ ...w, line: LINES.find((l) => l.id === w.line) }))
      .filter((w): w is typeof w & { line: Line } => Boolean(w.line));
    if (!wanted.length) return { body: { error: "unknown line" }, status: 404 };
    const feeds = await Promise.all([...new Set(wanted.map((w) => w.line.feed))].map(loadFeed));
    const now = Date.now();
    const departures = feeds
      .flatMap((feed) => feed.trips.flatMap((trip) => {
        const line = ROUTES.get(trip.routeId);
        return trip.stops.flatMap((s) => {
          const match = wanted.find((w) => w.line === line && w.stop === s.stop);
          if (!match || !s.time) return [];
          const last = trip.stops[trip.stops.length - 1]?.stop;
          return [{
            line: match.line.id,
            time: iso(s.time * 1000),
            live: trip.live ?? Boolean(trip.vehicle),
            destination: trip.destination ?? STOPS.get(last ?? "")?.name ?? "",
            vehicle: trip.vehicle && position(match.line, trip.vehicle),
          }];
        });
      }))
      .filter((d) => Date.parse(d.time) > now - 30_000)
      .sort((a, b) => Date.parse(a.time) - Date.parse(b.time))
      .slice(0, 20);
    const fetchedAt = Math.min(...feeds.map((f) => f.fetchedAt));
    const first = wanted[0].stop;
    return {
      body: {
        stop: { code: first, name: STOPS.get(first)?.name ?? "" },
        line: code,
        fetchedAt: iso(fetchedAt),
        nextRefreshAt: iso(fetchedAt + FEED_TTL_MS + 2_000),
        stale: now - fetchedAt > FEED_TTL_MS * 4,
        departures,
      },
    };
  }

  return { body: { error: "not found" }, status: 404 };
}

/** The lines that stop at a platform, each with the way it goes from there. */
function linesAt(stop: string) {
  return LINES.flatMap((l) => l.directions
    .filter((d) => d.stops.some((s) => s.code === stop))
    .map((d) => ({ line: l.id, direction: d.id, destination: d.destination })));
}

/**
 * Where to draw a train: at the station it's stopped at, or partway from the station before it
 * (along the line's stop order that way) to the one it's heading for.
 */
function position(line: Line, vehicle: TrainPosition) {
  const next = STOPS.get(vehicle.stop);
  if (!next) return undefined;
  const stops = line.directions.find((d) => d.id === vehicle.stop.slice(-1))?.stops ?? [];
  const index = stops.findIndex((s) => s.code === vehicle.stop);
  const previous = index > 0 ? stops[index - 1] : undefined;
  if (vehicle.status === STOPPED_AT || !previous) return { lat: next.lat, lon: next.lon };
  // Incoming: nearly there. In transit: somewhere along the way, so call it halfway.
  const t = vehicle.status === INCOMING_AT ? 0.8 : 0.5;
  const toRadians = Math.PI / 180;
  const bearing = Math.atan2(
    (next.lon - previous.lon) * Math.cos(previous.lat * toRadians),
    next.lat - previous.lat) / toRadians;
  return {
    lat: previous.lat + (next.lat - previous.lat) * t,
    lon: previous.lon + (next.lon - previous.lon) * t,
    bearing: (bearing + 360) % 360,
  };
}

// MARK: - The real-time feeds

export interface TrainPosition {
  stop: string;
  status: number;
}

export interface Trip {
  /** GTFS trip id; BART's feed names only this, not the route. */
  id?: string;
  routeId: string;
  stops: { stop: string; time: number }[];
  vehicle?: TrainPosition;
  /** Predicted from where the train is, though without a position (PATH). */
  live?: boolean;
  /** Where it's going, when `stops` doesn't run to the end of the line (PATH). */
  destination?: string;
}

interface Feed {
  trips: Trip[];
  fetchedAt: number;
}

/** Kept in memory only: a feed is a free request away, and too big for one storage value. */
const feeds = new Map<string, Promise<Feed>>();

async function loadFeed(name: string): Promise<Feed> {
  const cached = feeds.get(name);
  const feed = await cached?.catch(() => undefined);
  if (feed && Date.now() - feed.fetchedAt < FEED_TTL_MS) return feed;
  // Someone else's request may already be fetching a fresh copy.
  if (cached && feeds.get(name) !== cached) return feeds.get(name)!;
  return refresh(name, feed);
}

function refresh(name: string, previous?: Feed): Promise<Feed> {
  const load = fetch(name === "path" ? PATH_FEED : FEEDS + name)
    .then(async (response) => {
      if (!response.ok) throw new Error(`feed ${name}: ${response.status}`);
      const trips = name === "path" ? pathTrips(await response.json()) : decodeFeed(new Uint8Array(await response.arrayBuffer()));
      return { trips, fetchedAt: Date.now() };
    })
    // On a hiccup, keep serving the last copy (it'll say it's stale) and try again next time.
    .catch((error) => {
      if (previous) return { ...previous };
      feeds.delete(name);
      throw error;
    });
  feeds.set(name, load);
  return load;
}

// MARK: - PATH

/**
 * RidePATH's arrivals as one-stop trips. Each message is a train due at a station, going toward a
 * terminal ("target") in a direction ("ToNY"/"ToNJ"), in its line's color; the line is the PATH line
 * that way through the station ending at that terminal, the color telling apart the two Journal
 * Square–33rd Street ones (the one via Hoboken has both colors).
 */
function pathTrips(feed: any): Trip[] {
  const trips: Trip[] = [];
  for (const result of feed?.results ?? []) {
    const station = String(result.consideredStation ?? "");
    for (const destination of result.destinations ?? []) {
      const way = destination.label === "ToNY" ? "Y" : destination.label === "ToNJ" ? "J" : "";
      const stop = `P${station}${way}`;
      for (const message of destination.messages ?? []) {
        const colors = String(message.lineColor ?? "").toUpperCase().split(",").map((c) => `#${c.trim()}`);
        const line = LINES.find((l) => l.feed === "path" && l.directions.some((d) =>
          d.id === way && d.stops.some((s) => s.code === stop) && d.stops[d.stops.length - 1]?.code === `P${message.target}${way}`)
          && (colors.length > 1) === l.id.includes("via") && colors.includes(l.color ?? ""));
        const seconds = Number(message.secondsToArrival);
        const updated = Date.parse(message.lastUpdated) || Date.now();
        if (!line || !Number.isFinite(seconds)) continue;
        trips.push({
          routeId: line.routeId,
          stops: [{ stop, time: Math.round(updated / 1000 + seconds) }],
          live: true,
          destination: STOPS.get(`P${message.target}${way}`)?.name,
        });
      }
    }
  }
  return trips;
}

// MARK: - GTFS-realtime, the few fields used, straight from the protobuf wire format

const INCOMING_AT = 0, STOPPED_AT = 1;

class Reader {
  pos: number;
  constructor(readonly bytes: Uint8Array, start = 0, readonly end = bytes.length) {
    this.pos = start;
  }

  varint(): number {
    let result = 0, scale = 1, byte: number;
    do {
      byte = this.bytes[this.pos++];
      result += (byte & 0x7f) * scale;
      scale *= 128;
    } while (byte & 0x80);
    return result;
  }

  /** Each field as (number, wire type), with a reader for embedded messages and strings. */
  *fields(): Generator<{ field: number; wire: number; value: number; sub?: Reader }> {
    while (this.pos < this.end) {
      const tag = this.varint();
      const field = Math.floor(tag / 8), wire = tag & 7;
      if (wire === 0) yield { field, wire, value: this.varint() };
      else if (wire === 2) {
        const length = this.varint();
        const sub = new Reader(this.bytes, this.pos, this.pos + length);
        this.pos += length;
        yield { field, wire, value: length, sub };
      } else if (wire === 1) this.pos += 8;
      else if (wire === 5) this.pos += 4;
      else throw new Error(`unsupported wire type ${wire}`);
    }
  }

  string(): string {
    return decoder.decode(this.bytes.subarray(this.pos, this.end));
  }
}

const decoder = new TextDecoder();

/** FeedMessage → the trips with their upcoming stops, and where each running train is. */
export function decodeFeed(bytes: Uint8Array): Trip[] {
  const trips = new Map<string, Trip>();
  const trip = (id: string) => {
    let t = trips.get(id);
    if (!t) trips.set(id, (t = { id, routeId: "", stops: [] }));
    return t;
  };
  for (const entity of new Reader(bytes).fields()) {
    if (entity.field !== 2 || !entity.sub) continue;
    for (const part of entity.sub.fields()) {
      if (part.field === 3 && part.sub) {
        // TripUpdate: 1 trip, 2 stop_time_update.
        let descriptor = { id: "", route: "" };
        const stops: Trip["stops"] = [];
        for (const f of part.sub.fields()) {
          if (f.field === 1 && f.sub) descriptor = readTrip(f.sub);
          if (f.field === 2 && f.sub) stops.push(readStopTime(f.sub));
        }
        const t = trip(descriptor.id);
        t.routeId = descriptor.route;
        t.stops = stops;
      } else if (part.field === 4 && part.sub) {
        // VehiclePosition: 1 trip, 4 current_status, 5 timestamp, 7 stop_id.
        let descriptor = { id: "", route: "" };
        const vehicle: TrainPosition = { stop: "", status: 2 };
        let reported = Infinity;
        for (const f of part.sub.fields()) {
          if (f.field === 1 && f.sub) descriptor = readTrip(f.sub);
          if (f.field === 4) vehicle.status = f.value;
          if (f.field === 5) reported = f.value;
          if (f.field === 7 && f.sub) vehicle.stop = f.sub.string();
        }
        // Trips still waiting at the terminal are listed too, stamped with when they're due out;
        // only a train that has actually reported in is on its way.
        if (descriptor.id && vehicle.stop && reported <= Date.now() / 1000 + 60) trip(descriptor.id).vehicle = vehicle;
      }
    }
  }
  return [...trips.values()].filter((t) => t.stops.length);
}

/** TripDescriptor: 1 trip_id, 5 route_id. */
function readTrip(reader: Reader) {
  const trip = { id: "", route: "" };
  for (const f of reader.fields()) {
    if (f.field === 1 && f.sub) trip.id = f.sub.string();
    if (f.field === 5 && f.sub) trip.route = f.sub.string();
  }
  return trip;
}

/** StopTimeUpdate: 4 stop_id, 2 arrival / 3 departure, each a StopTimeEvent with 2 time. */
function readStopTime(reader: Reader) {
  const update = { stop: "", time: 0 };
  let arrival = 0, departure = 0;
  for (const f of reader.fields()) {
    if (f.field === 4 && f.sub) update.stop = f.sub.string();
    if ((f.field === 2 || f.field === 3) && f.sub) {
      for (const e of f.sub.fields()) {
        if (e.field === 2) f.field === 2 ? (arrival = e.value) : (departure = e.value);
      }
    }
  }
  // When the train leaves is what counts; at the end of the line there's only an arrival.
  update.time = departure || arrival;
  return update;
}

function iso(ms: number) {
  return new Date(ms).toISOString();
}
