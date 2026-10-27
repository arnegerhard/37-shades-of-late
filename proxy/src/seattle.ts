/**
 * Cities served from a OneBusAway server: Seattle (OneBusAway Puget Sound: King County Metro, Sound
 * Transit and the Seattle Streetcar) and New York's buses (MTA Bus Time, see nyc-bus.ts). Unlike 511,
 * OneBusAway has no "every stop at once" call, so departures are fetched per stop and cached for
 * DEPARTURES_TTL_MS while people keep asking for that stop.
 *
 *   GET /v1/seattle/lines                          all lines, `id` is the rider-facing code ("8", "E Line")
 *   GET /v1/seattle/lines/:line                    directions with stops and the real route shapes
 *   GET /v1/seattle/departures?stop=1_2260&line=8&direction=1
 *   GET /v1/seattle/nearby?stop=1_2260             lines at the stop and at stops within 150 m facing the same way
 *   GET /v1/seattle/map                            every line's route shape, for picking a line on a map
 */

import { closestPerLine, hexColor, mergeShapes, linePairs, linesAtStop, metersBetween, NEARBY_METERS, simplify, type NearbyLine, type Polyline } from "./geo";

const DEPARTURES_TTL_MS = 60_000;

/** What sets one OneBusAway city apart from another. */
export interface Region {
  /** The server's `api/where` address. */
  base: string;
  agencies: string[];
  /** Prefix of this region's cache keys ("sea" for Seattle, which had them first). */
  cache: string;
  /** A stop id, e.g. "1_2260" in Seattle or "MTA_308214" in New York. */
  stopPattern: RegExp;
  /** Routes to leave out, like substitute buses during track work. */
  skipRoute?: (route: any) => boolean;
  /** Tidies a stop or destination name, like MTA's all-caps ones. */
  stopName?: (name: string) => string;
  /** The upcoming visits at a stop; OneBusAway's own arrivals unless the region has a better source. */
  fetchStop?: (stop: string, deps: SeattleDeps) => Promise<StopData>;
}

export const SEATTLE: Region = {
  base: "https://api.pugetsound.onebusaway.org/api/where",
  // King County Metro, Sound Transit, City of Seattle (streetcars).
  agencies: ["1", "40", "23"],
  cache: "sea",
  stopPattern: /^\d+_\w+$/,
};

/** Long official names that don't fit in a line badge. */
const SHORT_CODES: Record<string, string> = {
  "South Lake Union Streetcar": "SLU",
  "First Hill Streetcar": "FHS",
};

export interface SeattleLine {
  id: string;
  name: string;
  mode: string;
  routeId: string;
  /** Official GTFS colors, e.g. Metro yellow, RapidRide red, Link green. */
  color?: string;
  textColor?: string;
}

export interface Visit {
  routeId: string;
  direction: string;
  destination: string;
  time: string;
  live: boolean;
  vehicle?: { lat: number; lon: number; bearing?: number };
}

export interface StopData {
  name: string;
  visits: Visit[];
}

type Cached = <T>(key: string, ttlSeconds: number, load: () => Promise<T>) => Promise<{ data: T; fetchedAt: number }>;

export interface SeattleDeps {
  cached: Cached;
  /** Reads a cache entry without loading it, however old. */
  peek: <T>(key: string) => Promise<{ data: T; fetchedAt: number } | undefined>;
  apiKey: string;
  staticTTL: number;
  /** Thrown when OneBusAway rate-limits us, so the cache serves what it has. */
  rateLimited: () => Error;
  upstream: (status: number) => Error;
}

export async function handleSeattle(parts: string[], url: URL, deps: SeattleDeps) {
  return handleOBA(parts, url, deps, SEATTLE);
}

export async function handleOBA(parts: string[], url: URL, baseDeps: SeattleDeps, region: Region) {
  const deps: Deps = { ...baseDeps, region };
  const stopList = new RegExp(`^${region.stopPattern.source.slice(1, -1)}(,${region.stopPattern.source.slice(1, -1)})*$`);
  const fetchStop = (stop: string) => (region.fetchStop ?? fetchOBAStop)(stop, deps);
  if (parts[0] === "lines" && parts.length === 1) {
    const { data, fetchedAt } = await linesCached(deps);
    return { body: { lines: data.map(({ id, name, mode }) => ({ id, name, mode })), fetchedAt: iso(fetchedAt) }, maxAge: 3600 };
  }

  if (parts[0] === "lines" && parts.length === 2) {
    const code = decodeURIComponent(parts[1]);
    const line = (await linesCached(deps)).data.find((l) => l.id === code);
    if (!line) return { body: { error: "unknown line" }, status: 404 };
    const { data, fetchedAt } = await deps.cached(`${region.cache}-line:${line.routeId}`, deps.staticTTL, () => fetchLine(line, deps));
    return { body: { line: code, directions: data, fetchedAt: iso(fetchedAt) }, maxAge: 3600 };
  }

  if (parts[0] === "map") {
    // A partial map (still being filled in, see fetchMap) is only kept briefly.
    let entry = await deps.cached(`${region.cache}-map-v5`, deps.staticTTL, () => fetchMap(deps));
    if (!entry.data.complete && Date.now() - entry.fetchedAt > 20_000) {
      entry = await deps.cached(`${region.cache}-map-v5`, 20, () => fetchMap(deps));
    }
    return { body: { lines: entry.data.lines, complete: entry.data.complete, fetchedAt: iso(entry.fetchedAt) }, maxAge: entry.data.complete ? 3600 : 0 };
  }

  if (parts[0] === "stop") {
    const stop = url.searchParams.get("stop") ?? "";
    if (!region.stopPattern.test(stop)) return { body: { error: "stop (agency_id) is required" }, status: 400 };
    const codes = new Map((await linesCached(deps)).data.map((l) => [l.routeId, l.id]));
    const entry = await deps.cached(`${region.cache}-stop:${stop}`, DEPARTURES_TTL_MS / 1000, () => fetchStop(stop));
    const visits = entry.data.visits.map((v) => ({ ...v, line: codes.get(v.routeId) ?? "" }));
    return { body: { stop: { code: stop, name: entry.data.name }, lines: linesAtStop(visits) } };
  }

  if (parts[0] === "nearby") {
    const stop = url.searchParams.get("stop") ?? "";
    if (!region.stopPattern.test(stop)) return { body: { error: "stop (agency_id) is required" }, status: 400 };
    const codes = new Map((await linesCached(deps)).data.map((l) => [l.routeId, l.id]));
    const [here, around] = await Promise.all([
      deps.cached(`${region.cache}-stop:${stop}`, DEPARTURES_TTL_MS / 1000, () => fetchStop(stop)),
      deps.cached(`${region.cache}-nearby-v1:${stop}`, deps.staticTTL, () => fetchNearbyStops(stop, deps)),
    ]);
    const found: NearbyLine[] = linesAtStop(here.data.visits.map((v) => ({ ...v, line: codes.get(v.routeId) ?? "" })))
      .map((l) => ({ ...l, stop, stopName: here.data.name, distance: 0 }));
    // A nearby stop faces the same way, so its lines go that way there; no direction needed.
    for (const s of around.data) {
      for (const routeId of s.routeIds) {
        const line = codes.get(routeId);
        if (line) found.push({ line, direction: "", destination: "", stop: s.code, stopName: s.name, distance: s.distance, lat: s.lat, lon: s.lon });
      }
    }
    // Lines already at the picked stop don't need a walk.
    const atStop = new Set(found.filter((l) => l.distance === 0).map((l) => l.line));
    return { body: { stop: { code: stop }, lines: closestPerLine(found.filter((l) => l.distance === 0 || !atStop.has(l.line))) } };
  }

  if (parts[0] === "departures") {
    const stop = url.searchParams.get("stop") ?? "";
    const code = url.searchParams.get("line");
    const direction = url.searchParams.get("direction");
    // `stop` may be a list too, a stop per line, for lines caught at a nearby stop.
    if (!stopList.test(stop) || !code) return { body: { error: "stop (agency_id) and line are required" }, status: 400 };
    const lines = (await linesCached(deps)).data;
    const wanted = linePairs(code, direction, stop)
      .map((w) => ({ ...w, routeId: lines.find((l) => l.id === w.line)?.routeId }));
    const stops = [...new Set(wanted.map((w) => w.stop))];
    const entries = await Promise.all(
      stops.map((s) => deps.cached(`${region.cache}-stop:${s}`, DEPARTURES_TTL_MS / 1000, () => fetchStop(s))));
    const now = Date.now();
    const departures = entries
      .flatMap((entry, i) => entry.data.visits.flatMap((v) => {
        const match = wanted.find((w) => w.stop === stops[i] && w.routeId === v.routeId && (!w.direction || w.direction === v.direction));
        return match ? [{ ...v, line: match.line }] : [];
      }))
      .filter((v) => Date.parse(v.time) > now - 30_000)
      .sort((a, b) => Date.parse(a.time) - Date.parse(b.time))
      .map(({ line, time, live, destination, vehicle }) => ({ line, time, live, destination, vehicle }));
    const fetchedAt = Math.min(...entries.map((e) => e.fetchedAt));
    return {
      body: {
        stop: { code: stops[0], name: entries[0].data.name },
        line: code,
        fetchedAt: iso(fetchedAt),
        nextRefreshAt: iso(fetchedAt + DEPARTURES_TTL_MS + 2_000),
        stale: now - fetchedAt > DEPARTURES_TTL_MS * 3,
        departures,
      },
    };
  }

  return { body: { error: "not found" }, status: 404 };
}

type Deps = SeattleDeps & { region: Region };

function linesCached(deps: Deps) {
  return deps.cached(`${deps.region.cache}-lines-v3`, deps.staticTTL, () => fetchLines(deps));
}

async function callOBA(path: string, params: Record<string, string>, deps: Deps): Promise<any> {
  const url = new URL(`${deps.region.base}/${path}.json`);
  url.search = new URLSearchParams({ ...params, key: deps.apiKey, version: "2" }).toString();
  // OneBusAway rate-limits per key (the shared TEST key to a request every several seconds),
  // so back off and retry a couple of times before giving up.
  for (const wait of [0, 5_000, 12_000]) {
    if (wait) await new Promise((resolve) => setTimeout(resolve, wait));
    const response = await fetch(url);
    const body: any = await response.json().catch(() => ({}));
    if (response.status === 429 || body.code === 429) continue;
    if (!response.ok || body.code !== 200) throw deps.upstream(body.code ?? response.status);
    return body.data;
  }
  throw deps.rateLimited();
}

async function fetchLines(deps: Deps): Promise<SeattleLine[]> {
  const routes: any[] = [];
  for (const agency of deps.region.agencies) {
    // Sequential on purpose: the shared TEST key allows only a request every few seconds.
    const list: any[] = (await callOBA(`routes-for-agency/${encodeURIComponent(agency)}`, {}, deps)).list ?? [];
    routes.push(...list.filter((route) => !deps.region.skipRoute?.(route)));
  }
  const uses = new Map<string, number>();
  for (const route of routes) uses.set(route.shortName, (uses.get(route.shortName) ?? 0) + 1);

  const lines: SeattleLine[] = [];
  for (const route of routes) {
    const longName = String(route.longName || route.description || "");
    let code = SHORT_CODES[route.shortName] ?? String(route.shortName || longName);
    // Sound Transit has two routes both called "Shuttle"; tell them apart by their long name.
    if ((uses.get(route.shortName) ?? 0) > 1) code = longName.replace(/ Bus$/, "") || `${code} ${route.id}`;
    lines.push({
      id: code,
      name: SHORT_CODES[route.shortName] ? String(route.shortName) : longName,
      mode: route.type === 3 ? "bus" : route.type === 2 ? "rail" : "metro",
      routeId: String(route.id),
      color: hexColor(route.color),
      textColor: hexColor(route.textColor),
    });
  }
  return lines.sort((a, b) => a.id.localeCompare(b.id, "en", { numeric: true }));
}

async function fetchLine(line: SeattleLine, deps: Deps) {
  const data = await callOBA(`stops-for-route/${encodeURIComponent(line.routeId)}`, { includePolylines: "true" }, deps);
  const stops = new Map<string, any>((data.references?.stops ?? []).map((s: any) => [s.id, s]));
  const groups = data.entry?.stopGroupings?.find((g: any) => g.type === "direction")?.stopGroups ?? [];
  return groups.map((group: any) => {
    const rawDestination = String(group.name?.name ?? "");
    const destination = deps.region.stopName?.(rawDestination) ?? rawDestination;
    return {
      id: String(group.id),
      name: destination,
      destination,
      stops: (group.stopIds ?? []).map((id: string) => {
        const stop = stops.get(id);
        const name = String(stop?.name ?? id).replace(/\s+/g, " ").trim();
        return { code: id, name: deps.region.stopName?.(name) ?? name, lat: stop?.lat, lon: stop?.lon };
      }),
      // The real street-level route, as one or more [[lat, lon], ...] segments.
      shapes: (group.polylines ?? []).map((p: any) => decodePolyline(p.points)),
    };
  });
}

/** Line fetches per request: Cloudflare's free plan allows about 50 outgoing requests per request. */
const MAP_FETCHES_PER_REQUEST = 35;

/**
 * Every line with its route shape, built in installments: each call fetches up to
 * MAP_FETCHES_PER_REQUEST lines that aren't cached (or are a day old) and uses whatever is
 * cached for the rest, so a cold map fills in over about five requests and a daily refresh
 * never shows gaps.
 */
async function fetchMap(deps: Deps) {
  const lines = (await linesCached(deps)).data;
  let budget = MAP_FETCHES_PER_REQUEST;
  let complete = true;
  const result: { id: string; name: string; mode: string; color?: string; textColor?: string; shapes: Polyline[] }[] = [];
  for (const line of lines) {
    const key = `${deps.region.cache}-line:${line.routeId}`;
    let entry = await deps.peek<any[]>(key);
    const fresh = entry && Date.now() - entry.fetchedAt < deps.staticTTL * 1000;
    if (!fresh && budget > 0) {
      budget--;
      try {
        entry = await deps.cached(key, deps.staticTTL, () => fetchLine(line, deps));
      } catch {
        // Keep whatever we had; try again on a later request.
      }
    }
    if (!entry) {
      complete = false;
      continue;
    }
    if (!fresh && budget <= 0) complete = false;
    // One direction is enough to draw the line; the other mostly retraces it. Its pieces are merged
    // into as few lines as possible, and simplified more: a city-wide map needs no street-level detail.
    const shapes = mergeShapes((entry.data[0]?.shapes ?? []).map((shape: Polyline) => simplify(shape, 20)));
    if (shapes.length) result.push({ id: line.id, name: line.name, mode: line.mode, color: line.color, textColor: line.textColor, shapes });
  }
  return { lines: result, complete };
}

interface NearbyStop {
  code: string;
  name: string;
  lat: number;
  lon: number;
  distance: number;
  routeIds: string[];
}

/** OneBusAway's stop orientations, as compass bearings. */
const HEADINGS: Record<string, number> = { N: 0, NE: 45, E: 90, SE: 135, S: 180, SW: 225, W: 270, NW: 315 };

/**
 * Stops within NEARBY_METERS of `stop` that face the same way (OneBusAway gives each stop the
 * direction its buses leave in), so the stop across the street isn't offered.
 */
async function fetchNearbyStops(stop: string, deps: Deps): Promise<NearbyStop[]> {
  const here = (await callOBA(`stop/${stop}`, {}, deps)).entry;
  const heading = HEADINGS[String(here?.direction ?? "")];
  if (heading === undefined) return [];
  const list: any[] = (await callOBA("stops-for-location", {
    lat: String(here.lat), lon: String(here.lon), radius: String(NEARBY_METERS),
  }, deps)).list ?? [];
  return list.flatMap((s) => {
    const other = HEADINGS[String(s.direction ?? "")];
    if (s.id === stop || other === undefined) return [];
    const turn = Math.abs(((other - heading + 540) % 360) - 180);
    const distance = Math.round(metersBetween(here, s));
    return turn <= 45 && distance <= NEARBY_METERS
      ? [{ code: String(s.id), name: deps.region.stopName?.(String(s.name ?? "")) ?? String(s.name ?? ""), lat: Number(s.lat), lon: Number(s.lon), distance, routeIds: (s.routeIds ?? []).map(String) }]
      : [];
  });
}

async function fetchOBAStop(stop: string, deps: Deps): Promise<StopData> {
  const data = await callOBA(`arrivals-and-departures-for-stop/${stop}`, { minutesBefore: "0", minutesAfter: "120" }, deps);
  const trips = new Map<string, any>((data.references?.trips ?? []).map((t: any) => [t.id, t]));
  const stopInfo = (data.references?.stops ?? []).find((s: any) => s.id === stop);
  const visits: Visit[] = [];
  for (const arrival of data.entry?.arrivalsAndDepartures ?? []) {
    const predicted = arrival.predictedDepartureTime || arrival.predictedArrivalTime;
    const time = predicted || arrival.scheduledDepartureTime || arrival.scheduledArrivalTime;
    if (!time) continue;
    const status = arrival.tripStatus;
    // OneBusAway predicts future trips from the assigned bus's current run, wherever that is;
    // only call it live (and show the bus) once the bus is actually running this trip.
    const running = Boolean(predicted && status?.activeTripId === arrival.tripId && status?.position);
    const visit: Visit = {
      routeId: String(arrival.routeId),
      direction: String(trips.get(arrival.tripId)?.directionId ?? ""),
      destination: String(arrival.tripHeadsign ?? ""),
      time: new Date(time).toISOString(),
      live: running,
    };
    if (running) {
      // OneBusAway's orientation is counterclockwise from east; bearings are clockwise from north.
      const orientation = Number(status.orientation);
      visit.vehicle = {
        lat: Number(status.position.lat),
        lon: Number(status.position.lon),
        bearing: Number.isFinite(orientation) ? (((90 - orientation) % 360) + 360) % 360 : undefined,
      };
    }
    visits.push(visit);
  }
  visits.sort((a, b) => Date.parse(a.time) - Date.parse(b.time));
  return { name: String(stopInfo?.name ?? "").replace(/\s+/g, " ").trim(), visits };
}

/** Google's encoded polyline format, as used by OneBusAway. Returns [[lat, lon], ...]. */
function decodePolyline(encoded: string): [number, number][] {
  const points: [number, number][] = [];
  let index = 0, lat = 0, lon = 0;
  while (index < encoded.length) {
    for (const axis of [0, 1]) {
      let result = 0, shift = 0, byte: number;
      do {
        byte = encoded.charCodeAt(index++) - 63;
        result |= (byte & 0x1f) << shift;
        shift += 5;
      } while (byte >= 0x20);
      const delta = result & 1 ? ~(result >> 1) : result >> 1;
      if (axis === 0) lat += delta; else lon += delta;
    }
    points.push([Math.round(lat) / 1e5, Math.round(lon) / 1e5]);
  }
  return points;
}

function iso(ms: number) {
  return new Date(ms).toISOString();
}
