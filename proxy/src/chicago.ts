/**
 * Chicago: the CTA's 'L' (Red, Blue, Brown, Green, Orange, Purple, Pink and Yellow Lines) and its buses.
 * The network (lines, their stops in order per direction, shapes and colors) is built ahead of time from
 * the CTA's static GTFS by scripts/chicago.py into chicago.json, as its schedule is far too big to read
 * here. Live times come per stop, kept for TTL_MS while people keep asking: the trains' from Train
 * Tracker (CTA_API_KEY), with where each train is, the buses' from Bus Tracker (CTA_BUS_KEY), which
 * takes a key of its own. Without one, those stops have no departures. Both allow 100,000 calls a day,
 * about 35 stops watched around the clock. Served under /v1/chicago/... like Boston (see boston.ts,
 * which serves both).
 *
 * The Brown, Orange, Pink and Purple Lines run out and back as one trip; the network splits them into
 * "out" (toward the Loop) and "back", and a train's way at a stop is the one that stop is on.
 */

import { serveNetwork, type Line, type Visit } from "./boston";
import network from "./chicago.json";

const TRAIN_TRACKER = "https://lapi.transitchicago.com/api/1.0/ttarrivals.aspx";
const BUS_TRACKER = "https://www.ctabustracker.com/bustime/api/v2/getpredictions";
const TTL_MS = 30_000;

export interface ChicagoDeps {
  cached: <T>(key: string, ttlSeconds: number, load: () => Promise<T>) => Promise<{ data: T; fetchedAt: number }>;
  trainKey?: string;
  busKey?: string;
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

export async function handleChicago(parts: string[], url: URL, deps: ChicagoDeps) {
  return serveNetwork(parts, url, lines, async (stopCodes) => {
    const entries = await Promise.all(stopCodes.map((stop) =>
      deps.cached(`chi-stop:${stop}`, TTL_MS / 1000, () => fetchStop(stop, deps)).catch(() => ({ data: [] as Visit[], fetchedAt: Date.now() }))));
    return { visits: entries.map((e) => e.data), fetchedAt: Math.min(...entries.map((e) => e.fetchedAt)), ttl: TTL_MS };
  });
}

const railRoutes = new Set(lines.filter((l) => l.mode === "subway").map((l) => l.routeId));
const routesAt = new Map<string, Set<string>>();
for (const line of lines) {
  for (const d of line.directions) for (const s of d.stops) routesAt.set(s.code, (routesAt.get(s.code) ?? new Set()).add(line.routeId));
}

/** A stop's coming departures: a train platform's from Train Tracker, a bus stop's from Bus Tracker. */
async function fetchStop(stop: string, deps: ChicagoDeps): Promise<Visit[]> {
  const rail = [...(routesAt.get(stop) ?? [])].some((r) => railRoutes.has(r));
  if (rail) {
    if (!deps.trainKey) return [];
    const body: any = await (await fetch(`${TRAIN_TRACKER}?key=${encodeURIComponent(deps.trainKey)}&stpid=${encodeURIComponent(stop)}&max=20&outputType=JSON`)).json();
    if (body.ctatt?.errCd && body.ctatt.errCd !== "0") throw new Error(`Train Tracker: ${body.ctatt.errNm}`);
    return (body.ctatt?.eta ?? []).flatMap((e: any) => {
      const way = wayAt.get(`${e.rt}|${stop}`);
      if (!way) return [];
      const lat = Number(e.lat), lon = Number(e.lon), heading = Number(e.heading);
      return [{
        routeId: e.rt, direction: way.direction, destination: e.destNm || way.destination,
        time: chicagoTime(e.arrT),
        // A train that hasn't left its terminal yet is a scheduled time ("isSch").
        live: e.isSch !== "1",
        vehicle: lat && lon ? { lat, lon, bearing: Number.isFinite(heading) ? heading : undefined } : undefined,
      }];
    });
  }
  if (!deps.busKey) return [];
  const body: any = await (await fetch(`${BUS_TRACKER}?key=${encodeURIComponent(deps.busKey)}&stpid=${encodeURIComponent(stop)}&top=20&format=json`)).json();
  const error = body["bustime-response"]?.error?.[0]?.msg;
  // No arrival scheduled in the next while is an error to Bus Tracker; to us it's no buses.
  if (error && !/no (arrival|service)/i.test(error)) throw new Error(`Bus Tracker: ${error}`);
  return (body["bustime-response"]?.prd ?? []).flatMap((p: any) => {
    const way = wayAt.get(`${p.rt}|${stop}`);
    if (!way) return [];
    // "20261030 10:57" in Chicago.
    const time = chicagoTime(`${p.prdtm.slice(0, 4)}-${p.prdtm.slice(4, 6)}-${p.prdtm.slice(6, 8)}T${p.prdtm.slice(9)}:00`);
    return [{ routeId: p.rt, direction: way.direction, destination: p.des || way.destination, time, live: true }];
  });
}

/** "2026-10-30T10:57:35", in Chicago, as an ISO time. */
function chicagoTime(local: string): string {
  const guess = Date.parse(`${local}Z`);
  // "GMT-5" in summer, "GMT-6" in winter, as of then.
  const offset = new Intl.DateTimeFormat("en-US", { timeZone: "America/Chicago", timeZoneName: "shortOffset" })
    .formatToParts(guess).find((p) => p.type === "timeZoneName")?.value ?? "GMT-6";
  return new Date(guess - Number(offset.replace("GMT", "") || 0) * 3600_000).toISOString();
}
