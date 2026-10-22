/**
 * Seattle, from OneBusAway Puget Sound: King County Metro, Sound Transit and the Seattle
 * Streetcar. Unlike 511, OneBusAway has no "every stop at once" call, so departures are fetched
 * per stop and cached for DEPARTURES_TTL_MS while people keep asking for that stop.
 *
 *   GET /v1/seattle/lines                          all lines, `id` is the rider-facing code ("8", "E Line")
 *   GET /v1/seattle/lines/:line                    directions with stops and the real route shapes
 *   GET /v1/seattle/departures?stop=1_2260&line=8&direction=1
 */

const OBA = "https://api.pugetsound.onebusaway.org/api/where";
/** King County Metro, Sound Transit, City of Seattle (streetcars). */
const AGENCIES = ["1", "40", "23"];
const DEPARTURES_TTL_MS = 60_000;

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
}

interface Visit {
  routeId: string;
  direction: string;
  destination: string;
  time: string;
  live: boolean;
  vehicle?: { lat: number; lon: number; bearing?: number };
}

interface StopData {
  name: string;
  visits: Visit[];
}

type Cached = <T>(key: string, ttlSeconds: number, load: () => Promise<T>) => Promise<{ data: T; fetchedAt: number }>;

export interface SeattleDeps {
  cached: Cached;
  apiKey: string;
  staticTTL: number;
  /** Thrown when OneBusAway rate-limits us, so the cache serves what it has. */
  rateLimited: () => Error;
  upstream: (status: number) => Error;
}

export async function handleSeattle(parts: string[], url: URL, deps: SeattleDeps) {
  if (parts[0] === "lines" && parts.length === 1) {
    const { data, fetchedAt } = await linesCached(deps);
    return { body: { lines: data.map(({ id, name, mode }) => ({ id, name, mode })), fetchedAt: iso(fetchedAt) }, maxAge: 3600 };
  }

  if (parts[0] === "lines" && parts.length === 2) {
    const code = decodeURIComponent(parts[1]);
    const line = (await linesCached(deps)).data.find((l) => l.id === code);
    if (!line) return { body: { error: "unknown line" }, status: 404 };
    const { data, fetchedAt } = await deps.cached(`sea-line:${line.routeId}`, deps.staticTTL, () => fetchLine(line, deps));
    return { body: { line: code, directions: data, fetchedAt: iso(fetchedAt) }, maxAge: 3600 };
  }

  if (parts[0] === "departures") {
    const stop = url.searchParams.get("stop") ?? "";
    const code = url.searchParams.get("line");
    const direction = url.searchParams.get("direction");
    if (!/^\d+_\w+$/.test(stop) || !code) return { body: { error: "stop (agency_id) and line are required" }, status: 400 };
    const line = (await linesCached(deps)).data.find((l) => l.id === code);
    const entry = await deps.cached(`sea-stop:${stop}`, DEPARTURES_TTL_MS / 1000, () => fetchStop(stop, deps));
    const now = Date.now();
    const departures = entry.data.visits
      .filter((v) => v.routeId === line?.routeId && (!direction || v.direction === direction))
      .filter((v) => Date.parse(v.time) > now - 30_000)
      .map(({ time, live, destination, vehicle }) => ({ time, live, destination, vehicle }));
    return {
      body: {
        stop: { code: stop, name: entry.data.name },
        line: code,
        fetchedAt: iso(entry.fetchedAt),
        nextRefreshAt: iso(entry.fetchedAt + DEPARTURES_TTL_MS + 2_000),
        stale: now - entry.fetchedAt > DEPARTURES_TTL_MS * 3,
        departures,
      },
    };
  }

  return { body: { error: "not found" }, status: 404 };
}

function linesCached(deps: SeattleDeps) {
  return deps.cached("sea-lines-v2", deps.staticTTL, () => fetchLines(deps));
}

async function callOBA(path: string, params: Record<string, string>, deps: SeattleDeps): Promise<any> {
  const url = new URL(`${OBA}/${path}.json`);
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

async function fetchLines(deps: SeattleDeps): Promise<SeattleLine[]> {
  const routes: any[] = [];
  for (const agency of AGENCIES) {
    // Sequential on purpose: the shared TEST key allows only a request every few seconds.
    routes.push(...((await callOBA(`routes-for-agency/${agency}`, {}, deps)).list ?? []));
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
    });
  }
  return lines.sort((a, b) => a.id.localeCompare(b.id, "en", { numeric: true }));
}

async function fetchLine(line: SeattleLine, deps: SeattleDeps) {
  const data = await callOBA(`stops-for-route/${line.routeId}`, { includePolylines: "true" }, deps);
  const stops = new Map<string, any>((data.references?.stops ?? []).map((s: any) => [s.id, s]));
  const groups = data.entry?.stopGroupings?.find((g: any) => g.type === "direction")?.stopGroups ?? [];
  return groups.map((group: any) => {
    const destination = String(group.name?.name ?? "");
    return {
      id: String(group.id),
      name: destination,
      destination,
      stops: (group.stopIds ?? []).map((id: string) => {
        const stop = stops.get(id);
        return { code: id, name: String(stop?.name ?? id).replace(/\s+/g, " ").trim(), lat: stop?.lat, lon: stop?.lon };
      }),
      // The real street-level route, as one or more [[lat, lon], ...] segments.
      shapes: (group.polylines ?? []).map((p: any) => decodePolyline(p.points)),
    };
  });
}

async function fetchStop(stop: string, deps: SeattleDeps): Promise<StopData> {
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
