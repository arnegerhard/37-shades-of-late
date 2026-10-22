import { DurableObject } from "cloudflare:workers";

/**
 * Caching proxy in front of 511.org for SF Muni.
 *
 * Every request goes through a single Durable Object, so all users share one cache and
 * one rate budget for the 511 API key (60 requests/hour by default). Departures come from a
 * single snapshot of every Muni stop, fetched from 511 in one call and refreshed every
 * SNAPSHOT_TTL_SECONDS by an alarm while anyone has asked for departures in the last few
 * minutes, so every stop and user shares the same, equally fresh data at a fixed cost of
 * about one 511 call per refresh. When the hourly budget is spent, the last snapshot is
 * served with `stale: true`.
 *
 *   GET /v1/lines                          all Muni lines
 *   GET /v1/lines/:line                    a line's directions and their stops (with coordinates) in order
 *   GET /v1/departures?stop=13254&line=37  upcoming departures at a stop for one line, with each
 *                                          live bus's current position
 */

interface Env {
  CACHE: DurableObjectNamespace<TransitCache>;
  API_KEY_511: string;
  HOURLY_BUDGET: string;
  SNAPSHOT_TTL_SECONDS: string;
  STATIC_TTL_SECONDS: string;
  ANALYTICS_ENGINE?: AnalyticsEngineDataset;
}

const AGENCY = "SF";
const SITE = "https://37shadesoflate.com";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method !== "GET") return json({ error: "method not allowed" }, 405);
    const { pathname } = new URL(request.url);
    // These pages now live on the website; keep the old addresses working.
    if (pathname === "/privacy" || pathname === "/support") return Response.redirect(`${SITE}${pathname}`, 301);
    if (pathname === "/") return Response.redirect(SITE, 301);
    recordUsage(request, env);
    // "-v3": the shared-snapshot version runs in a fresh instance (the old per-stop one kept
    // serving stale code while busy). Bump the suffix again for a clean cache if ever needed.
    const stub = env.CACHE.get(env.CACHE.idFromName(`${AGENCY}-v3`));
    return stub.fetch(request);
  },
} satisfies ExportedHandler<Env>;

// MARK: - Response shapes

interface Line {
  id: string;
  name: string;
  mode: string;
}

interface Stop {
  code: string;
  name: string;
  lat?: number;
  lon?: number;
}

interface Direction {
  id: string;
  name: string;
  destination: string;
  stops: Stop[];
}

interface Vehicle {
  lat: number;
  lon: number;
  bearing?: number;
}

interface Visit {
  line: string;
  direction: string;
  destination: string;
  time: string;
  live: boolean;
  vehicle?: Vehicle;
}

interface StopData {
  name: string;
  visits: Visit[];
}

interface Snapshot {
  fetchedAt: number;
  stops: Map<string, StopData>;
}

/** Keep refreshing the snapshot for this long after the last departures request. */
const ACTIVE_WINDOW_MS = 5 * 60_000;
/** How long after a refresh starts the new snapshot is reliably ready (511 takes ~1.5s). */
const REFRESH_LEAD_MS = 4_000;
/** The snapshot (~2 MB) is stored split across this many keys to stay under value size limits. */
const SNAPSHOT_SHARDS = 16;

interface CacheEntry<T> {
  data: T;
  fetchedAt: number;
}

class BudgetExhausted extends Error {}

class UpstreamError extends Error {
  constructor(readonly status: number) {
    super(`511.org returned ${status}`);
  }
}

// MARK: - Durable Object

export class TransitCache extends DurableObject<Env> {
  private inFlight = new Map<string, Promise<CacheEntry<unknown>>>();
  // Cloudflare drops an idle Durable Object's memory after a few seconds, so the snapshot is
  // also saved to storage (SNAPSHOT_SHARDS rows per refresh) and reloaded after an eviction.
  private snapshot?: Snapshot;
  private snapshotLoad?: Promise<Snapshot>;
  private lastActivitySaved = 0;

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);
    try {
      if (parts[0] !== "v1") return json({ error: "not found" }, 404);

      if (parts[1] === "lines" && parts.length === 2) {
        const { data, fetchedAt } = await this.cached("lines", this.staticTTL, () => this.fetchLines());
        return json({ lines: data, fetchedAt: iso(fetchedAt) }, 200, 3600);
      }

      if (parts[1] === "lines" && parts.length === 3) {
        const line = decodeURIComponent(parts[2]);
        const { data, fetchedAt } = await this.cached(`line-v2:${line}`, this.staticTTL, () => this.fetchLine(line));
        return json({ line, directions: data, fetchedAt: iso(fetchedAt) }, 200, 3600);
      }

      if (parts[1] === "departures") {
        const stop = url.searchParams.get("stop");
        const line = url.searchParams.get("line");
        const direction = url.searchParams.get("direction");
        if (!stop || !/^\d+$/.test(stop) || !line) {
          return json({ error: "stop (numeric) and line are required" }, 400);
        }
        const snapshot = await this.currentSnapshot();
        const data = snapshot.stops.get(stop);
        const now = Date.now();
        const departures = (data?.visits ?? [])
          .filter((v) => v.line === line && (!direction || v.direction === direction))
          .filter((v) => Date.parse(v.time) > now - 30_000)
          .map(({ time, live, destination, vehicle }) => ({ time, live, destination, vehicle }));
        const ttl = this.snapshotTTL * 1000;
        return json({
          stop: { code: stop, name: data?.name ?? "" },
          line,
          fetchedAt: iso(snapshot.fetchedAt),
          // When a newer snapshot will be ready to ask for; also what the app's bar counts down to.
          nextRefreshAt: iso(snapshot.fetchedAt + ttl + REFRESH_LEAD_MS),
          stale: now - snapshot.fetchedAt > ttl * 3,
          departures,
        });
      }

      return json({ error: "not found" }, 404);
    } catch (error) {
      if (error instanceof BudgetExhausted) {
        return json({ error: "rate limited, try again shortly" }, 503, 0, { "Retry-After": "120" });
      }
      if (error instanceof UpstreamError) return json({ error: error.message }, 502);
      return json({ error: String(error) }, 500);
    }
  }

  private get snapshotTTL() {
    return Number(this.env.SNAPSHOT_TTL_SECONDS) || 70;
  }

  /** The latest snapshot, refreshing it first if it's expired and the budget allows. */
  private async currentSnapshot(): Promise<Snapshot> {
    await this.noteActivity();
    const snapshot = this.snapshot ?? (await this.loadStoredSnapshot());
    if (snapshot && Date.now() - snapshot.fetchedAt < this.snapshotTTL * 1000) {
      await this.scheduleRefresh();
      return snapshot;
    }
    try {
      return await this.refreshSnapshot();
    } catch (error) {
      if (snapshot && (error instanceof BudgetExhausted || error instanceof UpstreamError)) return snapshot;
      throw error;
    }
  }

  private refreshSnapshot(): Promise<Snapshot> {
    this.snapshotLoad ??= (async () => {
      try {
        this.snapshot = await this.fetchSnapshot();
        await this.storeSnapshot(this.snapshot);
        return this.snapshot;
      } finally {
        this.snapshotLoad = undefined;
        await this.scheduleRefresh();
      }
    })();
    return this.snapshotLoad;
  }

  /** Records that someone wants departures, writing to storage at most once a minute. */
  private async noteActivity() {
    if (Date.now() - this.lastActivitySaved < 60_000) return;
    this.lastActivitySaved = Date.now();
    await this.ctx.storage.put("lastActivity", this.lastActivitySaved);
  }

  private async storeSnapshot(snapshot: Snapshot) {
    const shards: Record<string, StopData>[] = Array.from({ length: SNAPSHOT_SHARDS }, () => ({}));
    for (const [code, stop] of snapshot.stops) shards[Number(code) % SNAPSHOT_SHARDS][code] = stop;
    const entries: Record<string, unknown> = { "snapshot:fetchedAt": snapshot.fetchedAt };
    shards.forEach((shard, i) => (entries[`snapshot:${i}`] = shard));
    await this.ctx.storage.put(entries);
  }

  private async loadStoredSnapshot(): Promise<Snapshot | undefined> {
    const fetchedAt = await this.ctx.storage.get<number>("snapshot:fetchedAt");
    if (!fetchedAt) return undefined;
    const keys = Array.from({ length: SNAPSHOT_SHARDS }, (_, i) => `snapshot:${i}`);
    const shards = await this.ctx.storage.get<Record<string, StopData>>(keys);
    const stops = new Map<string, StopData>();
    for (const shard of shards.values()) for (const [code, stop] of Object.entries(shard)) stops.set(code, stop);
    this.snapshot = { fetchedAt, stops };
    return this.snapshot;
  }

  /** Arms the alarm for the next refresh, unless one is already set. */
  private async scheduleRefresh() {
    if ((await this.ctx.storage.getAlarm()) !== null) return;
    const due = (this.snapshot?.fetchedAt ?? 0) + this.snapshotTTL * 1000;
    await this.ctx.storage.setAlarm(Math.max(due, Date.now() + 5_000));
  }

  /** Refreshes the snapshot on schedule while someone is using the app; otherwise lets it lapse. */
  async alarm() {
    const lastActivity = (await this.ctx.storage.get<number>("lastActivity")) ?? 0;
    if (Date.now() - lastActivity > ACTIVE_WINDOW_MS) return;
    try {
      await this.refreshSnapshot();
    } catch {
      // Budget spent or 511 down: try again next interval.
      await this.ctx.storage.setAlarm(Date.now() + this.snapshotTTL * 1000);
    }
  }

  private get staticTTL() {
    return Number(this.env.STATIC_TTL_SECONDS) || 86400;
  }

  /**
   * Returns the cached value when it's fresh. Otherwise refreshes it from 511 if the hourly
   * budget allows, falling back to whatever is cached (however old) when it doesn't.
   */
  private async cached<T>(key: string, ttlSeconds: number, load: () => Promise<T>): Promise<CacheEntry<T>> {
    const existing = await this.ctx.storage.get<CacheEntry<T>>(key);
    if (existing && Date.now() - existing.fetchedAt < ttlSeconds * 1000) return existing;

    const pending = this.inFlight.get(key) as Promise<CacheEntry<T>> | undefined;
    if (pending) return pending;

    const refresh = (async () => {
      try {
        const entry = { data: await load(), fetchedAt: Date.now() };
        await this.ctx.storage.put(key, entry);
        return entry;
      } catch (error) {
        if (existing && (error instanceof BudgetExhausted || error instanceof UpstreamError)) return existing;
        throw error;
      } finally {
        this.inFlight.delete(key);
      }
    })();
    this.inFlight.set(key, refresh);
    return refresh;
  }

  /** Spends one request from the rolling hourly budget, or throws if none is left. */
  private async spendBudget() {
    const hourAgo = Date.now() - 3600_000;
    const calls = ((await this.ctx.storage.get<number[]>("budget")) ?? []).filter((t) => t > hourAgo);
    if (calls.length >= (Number(this.env.HOURLY_BUDGET) || 55)) throw new BudgetExhausted();
    calls.push(Date.now());
    await this.ctx.storage.put("budget", calls);
  }

  private async call511(path: string, params: Record<string, string>): Promise<any> {
    await this.spendBudget();
    const url = new URL(`https://api.511.org/transit/${path}`);
    url.search = new URLSearchParams({ ...params, api_key: this.env.API_KEY_511, format: "json" }).toString();
    const response = await fetch(url, { headers: { "Accept-Encoding": "gzip" } });
    if (response.status === 429) {
      // 511 thinks we're over; burn the rest of the budget so we back off for a while.
      await this.ctx.storage.put("budget", Array(Number(this.env.HOURLY_BUDGET) || 55).fill(Date.now()));
      throw new BudgetExhausted();
    }
    if (!response.ok) throw new UpstreamError(response.status);
    // 511 prefixes its JSON with a byte order mark.
    return JSON.parse((await response.text()).replace(/^﻿/, ""));
  }

  // MARK: 511 endpoints

  private async fetchLines(): Promise<Line[]> {
    const lines: any[] = await this.call511("lines", { operator_id: AGENCY });
    return lines
      .map((l) => ({ id: String(l.Id), name: titleCase(String(l.Name ?? "")), mode: String(l.TransportMode ?? "bus") }))
      .sort((a, b) => a.id.localeCompare(b.id, "en", { numeric: true }));
  }

  private async fetchLine(line: string): Promise<Direction[]> {
    const [body, stops] = await Promise.all([
      this.call511("patterns", { operator_id: AGENCY, line_id: line }),
      this.call511("stops", { operator_id: AGENCY, line_id: line }),
    ]);
    const locations = new Map<string, { lat: number; lon: number }>();
    for (const stop of stops.Contents?.dataObjects?.ScheduledStopPoint ?? []) {
      const lat = Number(stop.Location?.Latitude);
      const lon = Number(stop.Location?.Longitude);
      if (lat && lon) locations.set(String(stop.id), { lat, lon });
    }
    const names = new Map<string, string>((body.directions ?? []).map((d: any) => [d.DirectionId, d.Name]));
    const byDirection = new Map<string, any[]>();
    for (const pattern of body.journeyPatterns ?? []) {
      const list = byDirection.get(pattern.DirectionRef) ?? [];
      list.push(pattern);
      byDirection.set(pattern.DirectionRef, list);
    }

    return [...byDirection.entries()].map(([id, patterns]) => {
      const sequences = patterns.map(patternStops).sort((a, b) => b.length - a.length);
      const main = patterns.reduce((a, b) => (patternStops(b).length > patternStops(a).length ? b : a));
      return {
        id,
        name: names.get(id) ?? id,
        destination: main.DestinationDisplayView?.FontText || main.Name || "",
        stops: mergeSequences(sequences).map((stop) => ({ ...stop, ...locations.get(stop.code) })),
      };
    });
  }

  /** Every upcoming arrival at every stop, from one 511 call (~10 MB of JSON). */
  private async fetchSnapshot(): Promise<Snapshot> {
    const body = await this.call511("StopMonitoring", { agency: AGENCY });
    const visits: any[] = body.ServiceDelivery?.StopMonitoringDelivery?.MonitoredStopVisit ?? [];
    const stops = new Map<string, StopData>();
    for (const visit of visits) {
      const journey = visit.MonitoredVehicleJourney ?? {};
      const call = journey.MonitoredCall ?? {};
      const code = String(call.StopPointRef ?? visit.MonitoringRef ?? "");
      const time =
        call.ExpectedDepartureTime ?? call.ExpectedArrivalTime ?? call.AimedDepartureTime ?? call.AimedArrivalTime;
      if (!code || !time) continue;
      let stop = stops.get(code);
      if (!stop) {
        stop = { name: String(call.StopPointName ?? ""), visits: [] };
        stops.set(code, stop);
      }
      stop.visits.push({
        line: String(journey.LineRef ?? ""),
        direction: String(journey.DirectionRef ?? ""),
        destination: String(call.DestinationDisplay ?? journey.DestinationName ?? ""),
        time: new Date(time).toISOString(),
        // Predictions without an assigned vehicle are schedule-based estimates.
        live: Boolean(journey.VehicleRef),
        vehicle: vehiclePosition(journey),
      });
    }
    for (const stop of stops.values()) stop.visits.sort((a, b) => Date.parse(a.time) - Date.parse(b.time));
    return { fetchedAt: Date.now(), stops };
  }
}

// MARK: - Usage statistics

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CLIENTS = new Set(["app", "widget", "map", "web"]);

/**
 * Logs one anonymous event per API request to Workers Analytics Engine. The app sends a random
 * install ID it generated itself (no account, Apple ID or device identifier) so usage can be
 * counted per install; IP addresses and locations are never recorded.
 *
 * Columns: blob1 event (departures | lines | line), blob2 client (app | widget | map | web),
 * blob3 line, blob4 stop, blob5 direction, blob6 install ID, blob7 app version,
 * double1 number of favorites; index1 install ID (keeps sampling per install).
 */
function recordUsage(request: Request, env: Env) {
  if (!env.ANALYTICS_ENGINE) return;
  const url = new URL(request.url);
  const parts = url.pathname.split("/").filter(Boolean);
  if (parts[0] !== "v1") return;
  const event = parts[1] === "departures" ? "departures" : parts.length > 2 ? "line" : parts[1] ?? "";
  const header = (name: string) => (request.headers.get(name) ?? "").slice(0, 64);
  const install = UUID.test(header("X-Install-ID")) ? header("X-Install-ID").toLowerCase() : "unknown";
  // The website can't send custom headers without a CORS preflight, so it uses ?client=web.
  const claimed = header("X-Client") || (url.searchParams.get("client") ?? "");
  const client = CLIENTS.has(claimed) ? claimed : "unknown";
  const line = (event === "line" ? decodeURIComponent(parts[2]) : url.searchParams.get("line")) ?? "";
  const favorites = Number(header("X-Favorites"));
  env.ANALYTICS_ENGINE.writeDataPoint({
    blobs: [
      event,
      client,
      line.slice(0, 16),
      (url.searchParams.get("stop") ?? "").slice(0, 16),
      (url.searchParams.get("direction") ?? "").slice(0, 8),
      install,
      header("X-App-Version").slice(0, 16),
    ],
    doubles: [Number.isFinite(favorites) ? Math.max(0, Math.min(favorites, 1000)) : 0],
    indexes: [install],
  });
}

// MARK: - Helpers

function vehiclePosition(journey: any): Vehicle | undefined {
  const lat = Number(journey.VehicleLocation?.Latitude);
  const lon = Number(journey.VehicleLocation?.Longitude);
  if (!journey.VehicleRef || !lat || !lon) return undefined;
  const bearing = Number(journey.Bearing);
  return { lat, lon, bearing: Number.isFinite(bearing) && journey.Bearing !== null ? bearing : undefined };
}

function patternStops(pattern: any): { code: string; name: string }[] {
  const points = pattern.PointsInSequence ?? {};
  return [...(points.StopPointInJourneyPattern ?? []), ...(points.TimingPointInJourneyPattern ?? [])]
    .sort((a, b) => Number(a.Order) - Number(b.Order))
    .map((p) => ({ code: String(p.ScheduledStopPointRef), name: String(p.Name) }));
}

/** Longest pattern first, then any stops only served by shorter variants, placed after their predecessor. */
function mergeSequences(sequences: { code: string; name: string }[][]) {
  const merged = [...(sequences[0] ?? [])];
  for (const sequence of sequences.slice(1)) {
    sequence.forEach((stop, i) => {
      if (merged.some((s) => s.code === stop.code)) return;
      const before = i > 0 ? merged.findIndex((s) => s.code === sequence[i - 1].code) : -1;
      merged.splice(before + 1, 0, stop);
    });
  }
  return merged;
}

function titleCase(s: string) {
  return s.toLowerCase().replace(/\b[a-z]/g, (c) => c.toUpperCase());
}

function iso(ms: number) {
  return new Date(ms).toISOString();
}

function json(body: unknown, status = 200, maxAge = 0, headers: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": maxAge ? `public, max-age=${maxAge}` : "no-store",
      // Public transit data; lets the 37shadesoflate.com page show live times.
      "Access-Control-Allow-Origin": "*",
      ...headers,
    },
  });
}
