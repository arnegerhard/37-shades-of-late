/**
 * Los Angeles County's other bus operators, next to Metro (see la.ts): Beach Cities Transit (down Hermosa Ave),
 * Big Blue Bus, Culver CityBus, LADOT's DASH and Commuter Express, GTrans, Long Beach Transit, Foothill Transit,
 * Montebello, Norwalk, Pasadena, Burbank, Santa Clarita, Antelope Valley and Commerce. Their lines and stops are in
 * la.json, built by scripts/la.py with Metro's: lines as riders say them ("BCT 109", "BBB 7", "DASH A"), stops with
 * their operator's key ("BCT_1234"), and per operator its feeds and which line each of its routes is.
 *
 * Live times and buses come from each operator's GTFS-realtime feeds (open, no key), fetched only while someone
 * looks at one of its stops, at most every FEED_TTL_MS. Most of their feeds name a trip but not its route, so the
 * routes come from the operator's schedule (its trips.txt, read once a day from its static GTFS): its trip's
 * route, by name, is the line; and its direction, where the feed doesn't say one. Pasadena's and Santa Clarita's
 * feeds give only each bus's next stop; for theirs the schedule's times are read too, and a bus's delay there is
 * carried on to the stops after it.
 */

import { decodeTrips, type LiveTrip } from "./boston";
import { decodePositions, localDate, localMidnight } from "./ferries";
import { parseCSV, readZipEntry } from "./geo";
import network from "./la.json";

interface Operator {
  name: string;
  gtfs: string;
  tripUpdates: string;
  vehiclePositions: string;
  /** Which line each route is, by its short name (else its long name), as la.py names them. */
  routes: Record<string, string>;
  /** Whether its live feed gives only each bus's next stop. */
  nextStopOnly?: boolean;
}

const OPERATORS: Record<string, Operator> = (network as any).operators ?? {};

const FEED_TTL_MS = 20_000;
const SCHEDULE_TTL_MS = 24 * 3600_000;
/** A schedule that couldn't be had is tried again after this long. */
const SCHEDULE_RETRY_MS = 10 * 60_000;
const USER_AGENT = "Mozilla/5.0 (37 Shades of Late; https://37shadesoflate.com)";

/** The operator a stop code ("BCT_1234") is one of, if any. */
export function operatorOf(stop: string): string | undefined {
  const key = stop.slice(0, stop.indexOf("_"));
  return key && OPERATORS[key] ? key : undefined;
}

/** Foothill's schedule has its trips' ids with a version on the end ("12345-v4B-a1"); its live feeds without one,
 *  or with a newer one. A trip is its id without. */
const tripKey = (id: string) => id.replace(/-v[0-9a-f]+-a\d+$/i, "");

interface Schedule {
  /** By trip: its line's route id ("BCT:BCT 109") and direction ("" where the schedule has none). */
  trips: Map<string, { route: string; direction: string; times?: [stop: string, seconds: number][] }>;
  at: number;
}

const schedules = new Map<string, Promise<Schedule>>();

/** The operator's trips, once a day; yesterday's while a new copy fails. */
async function schedule(key: string): Promise<Schedule> {
  const cached = await schedules.get(key)?.catch(() => undefined);
  if (cached && Date.now() - cached.at < SCHEDULE_TTL_MS) return cached;
  const operator = OPERATORS[key];
  const next = (async () => {
    const response = await fetch(operator.gtfs, { headers: { "User-Agent": USER_AGENT } });
    if (!response.ok) throw new Error(`${key} GTFS: ${response.status}`);
    const zip = await response.arrayBuffer();
    const [routes, trips, stopTimes] = await Promise.all(["routes.txt", "trips.txt", ...(operator.nextStopOnly ? ["stop_times.txt"] : [])]
      .map(async (name) => parseCSV((await readZipEntry(zip, name)) ?? "")));
    // Each trip's times at its stops, in order, as seconds after its service day's midnight.
    const times = new Map<string, [number, string, number][]>();
    for (const st of stopTimes ?? []) {
      const [h, m, sec] = (st.departure_time || st.arrival_time || "").split(":").map(Number);
      if (!Number.isFinite(h)) continue;
      const list = times.get(st.trip_id) ?? [];
      list.push([Number(st.stop_sequence), st.stop_id, h * 3600 + m * 60 + (sec || 0)]);
      times.set(st.trip_id, list);
    }
    const lineOf = new Map(routes.map((r) => [r.route_id, operator.routes[(r.route_short_name ?? "").trim() || (r.route_long_name ?? "").trim()]]));
    const found: Schedule["trips"] = new Map();
    for (const t of trips) {
      const route = lineOf.get(t.route_id);
      if (!route) continue;
      const own = times.get(t.trip_id)?.sort((a, b) => a[0] - b[0]).map(([, stop, at]): [string, number] => [stop, at]);
      found.set(tripKey(t.trip_id), { route, direction: t.direction_id ?? "", times: own });
    }
    if (!found.size) throw new Error(`${key} GTFS: no trips on its lines`);
    return { trips: found, at: Date.now() };
  })().catch((error) => {
    console.warn(`la: ${error}`);
    // The last copy if there is one, tried again in a while.
    if (cached) return { ...cached, at: Date.now() - SCHEDULE_TTL_MS + SCHEDULE_RETRY_MS };
    schedules.delete(key);
    throw error;
  });
  schedules.set(key, next);
  return next;
}

export interface OperatorLive {
  /** By "KEY:trip": its line's route id, direction and stops, coded as la.json's ("BCT_1234"). */
  trips: Map<string, LiveTrip>;
  positions: Map<string, { lat: number; lon: number; bearing?: number }>;
  fetchedAt: number;
}

const lives = new Map<string, Promise<OperatorLive>>();

/** The operator's live trips and buses, at most every FEED_TTL_MS; the last copy on a hiccup. */
export async function operatorLive(key: string): Promise<OperatorLive> {
  const cached = await lives.get(key)?.catch(() => undefined);
  if (cached && Date.now() - cached.fetchedAt < FEED_TTL_MS) return cached;
  const operator = OPERATORS[key];
  const next = (async () => {
    const get = async (url: string) => {
      const response = await fetch(url, { headers: { "User-Agent": USER_AGENT } });
      if (!response.ok) throw new Error(`${key} ${url}: ${response.status}`);
      return new Uint8Array(await response.arrayBuffer());
    };
    const [known, updates, at] = await Promise.all([
      schedule(key), get(operator.tripUpdates), get(operator.vehiclePositions).catch(() => undefined),
    ]);
    const trips = new Map<string, LiveTrip>();
    for (const [id, trip] of decodeTrips(updates, true, true)) {
      const scheduled = known.trips.get(tripKey(id));
      if (!scheduled) continue;
      const stops = scheduled.times ? onward(trip.stops, scheduled.times) : trip.stops;
      trips.set(`${key}:${tripKey(id)}`, {
        route: scheduled.route,
        direction: trip.direction || scheduled.direction,
        stops: new Map([...stops].map(([stop, time]) => [`${key}_${stop}`, time])),
      });
    }
    const positions = new Map([...(at ? decodePositions(at) : [])].map(([trip, p]) => [`${key}:${tripKey(trip)}`, p]));
    return { trips, positions, fetchedAt: Date.now() };
  })().catch((error) => {
    if (cached) return cached;
    lives.delete(key);
    throw error;
  });
  lives.set(key, next);
  return next;
}

/** A trip's live times at the stops the feed gives (its next one), and after the last of them, the schedule's
 *  with the delay it has there. The schedule's times are after a service day's midnight: the day that puts the
 *  live time nearest its scheduled one. */
function onward(live: Map<string, number>, times: [string, number][]): Map<string, number> {
  const index = new Map(times.map(([stop], i) => [stop, i]));
  const known = [...live].filter(([stop]) => index.has(stop)).sort((a, b) => index.get(a[0])! - index.get(b[0])!);
  const last = known.at(-1);
  if (!last) return live;
  const [stop, time] = last;
  const scheduled = times[index.get(stop)!][1];
  const midnights = [-1, 0].map((days) => localMidnight(localDate(time * 1000 + days * 86400_000, "America/Los_Angeles"), "America/Los_Angeles") / 1000);
  const midnight = midnights.sort((a, b) => Math.abs(time - (a + scheduled)) - Math.abs(time - (b + scheduled)))[0];
  const delay = time - (midnight + scheduled);
  const all = new Map(live);
  // Not the last stop: nobody gets on there.
  for (const [next, at] of times.slice(index.get(stop)! + 1, -1)) if (!all.has(next)) all.set(next, midnight + at + delay);
  return all;
}
