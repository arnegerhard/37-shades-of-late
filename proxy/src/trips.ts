import { eachZipRow, metersBetween, parseCSV, readZipEntry } from "./geo";

/**
 * Trips between two places (the app's trips): every way there by one line or two, the walks to, between and
 * from them weighed by the hills on them. Answers
 *
 *   GET /v1/trip?from=lat,lon&to=lat,lon     the ways, the quickest as they feel first
 *
 * from a city's network built once a day from its GTFS feed (`buildNetwork`): its stops, with their heights,
 * and each line's stop orders (patterns), with the minutes between stops and how often it runs. The search
 * is a small round-based one (as RAPTOR is): walks to the stops around the start, a ride, a walk to another
 * stop and a second ride, walks from the stops around the end.
 */

/** A stop: where, its name, and how high (meters, null unknown). */
type StopEntry = [lat: number, lon: number, name: string, height: number | null];

interface Pattern {
  line: string;
  /** IB or OB, as the live times have it. */
  direction: string;
  destination: string;
  stops: string[];
  /** Minutes from the first stop to each. */
  minutes: number[];
  /** Minutes to count for waiting for it: half the time between them, within reason. */
  wait: number;
}

export interface Network {
  stops: Record<string, StopEntry>;
  patterns: Pattern[];
}

// MARK: Building

/** A city's network from its GTFS feed: stop_times read a row at a time (it's over 100 MB unzipped), each
 *  trip's stops in order kept once per distinct order, the most-run orders of each line and direction. */
export async function buildNetwork(zip: ArrayBuffer, heights: (points: number[][]) => Promise<(number | null)[]>): Promise<Network> {
  const [routesText, directionsText] = await Promise.all(["routes.txt", "directions.txt"].map((name) => readZipEntry(zip, name)));
  if (!routesText) throw new Error("GTFS feed without routes");
  const lineOf = new Map(parseCSV(routesText).map((r) => [r.route_id, r.route_short_name || r.route_id]));
  const wayOf = new Map((directionsText ? parseCSV(directionsText) : []).map((d) => [`${d.route_id}|${d.direction_id}`,
    /^in/i.test(d.direction) ? "IB" : /^out/i.test(d.direction) ? "OB" : d.direction]));
  const way = (route: string, id: string) => wayOf.get(`${route}|${id}`) ?? (id === "1" ? "IB" : "OB");

  // Stops: their codes (what the app and the live times use), where, and names.
  const stops: Record<string, StopEntry> = {};
  const codeOf = new Map<string, string>();
  let c = { id: 0, code: -1, name: 2, lat: 3, lon: 4 };
  await eachZipRow(zip, "stops.txt", (h) => {
    c = { id: h.indexOf("stop_id"), code: h.indexOf("stop_code"), name: h.indexOf("stop_name"), lat: h.indexOf("stop_lat"), lon: h.indexOf("stop_lon") };
  }, (f) => {
    const code = (c.code >= 0 && f[c.code]) || f[c.id];
    const lat = Number(f[c.lat]), lon = Number(f[c.lon]);
    if (!code || !Number.isFinite(lat) || !Number.isFinite(lon)) return;
    codeOf.set(f[c.id], code);
    // Names may be quoted, with commas: only those without are read whole; the rest are trimmed of quotes.
    stops[code] = [lat, lon, (f[c.name] ?? "").replace(/^"|"$/g, ""), null];
  });

  // Trips: their line, way and destination, and how many of each line and way run a day (the busiest service's).
  const trips = new Map<string, { line: string; direction: string; destination: string }>();
  const perService = new Map<string, number>();
  let t = { route: 0, service: 1, trip: 2, headsign: 3, direction: 4 };
  await eachZipRow(zip, "trips.txt", (h) => {
    t = { route: h.indexOf("route_id"), service: h.indexOf("service_id"), trip: h.indexOf("trip_id"), headsign: h.indexOf("trip_headsign"), direction: h.indexOf("direction_id") };
  }, (f) => {
    const line = lineOf.get(f[t.route]);
    if (!line) return;
    const direction = way(f[t.route], f[t.direction]);
    trips.set(f[t.trip], { line, direction, destination: (f[t.headsign] ?? "").replace(/^"|"$/g, "") });
    const key = `${line}|${direction}|${f[t.service]}`;
    perService.set(key, (perService.get(key) ?? 0) + 1);
  });
  const daily = new Map<string, number>();
  for (const [key, count] of perService) {
    const lineWay = key.split("|").slice(0, 2).join("|");
    daily.set(lineWay, Math.max(daily.get(lineWay) ?? 0, count));
  }

  // Each trip's stops in order (the rows come trip by trip), kept once per distinct order, with how often it runs.
  const orders = new Map<string, { line: string; direction: string; destination: string; stops: string[]; minutes: number[]; count: number }>();
  let current = "", codes: string[] = [], times: number[] = [];
  const finish = () => {
    const trip = trips.get(current);
    if (trip && codes.length > 1) {
      const key = `${trip.line}|${trip.direction}|${codes.join(",")}`;
      const seen = orders.get(key);
      if (seen) seen.count++;
      else orders.set(key, { ...trip, stops: codes, minutes: times.map((m) => Math.round((m - times[0]) * 10) / 10), count: 1 });
    }
    codes = []; times = [];
  };
  let s = { trip: 0, departure: 2, stop: 3 };
  await eachZipRow(zip, "stop_times.txt", (h) => {
    s = { trip: h.indexOf("trip_id"), departure: h.indexOf("departure_time"), stop: h.indexOf("stop_id") };
  }, (f) => {
    if (f[s.trip] !== current) { finish(); current = f[s.trip]; }
    const [hh, mm, ss] = (f[s.departure] ?? "").split(":").map(Number);
    const code = codeOf.get(f[s.stop]);
    if (!code || !Number.isFinite(hh)) return;
    codes.push(code);
    times.push(hh * 60 + mm + (ss || 0) / 60);
  });
  finish();

  // The most-run orders of each line and way: the whole route and its usual short runs, not every variant.
  const byLineWay = new Map<string, typeof orders extends Map<string, infer V> ? V[] : never>();
  for (const order of orders.values()) {
    const key = `${order.line}|${order.direction}`;
    byLineWay.set(key, [...(byLineWay.get(key) ?? []), order]);
  }
  const patterns: Pattern[] = [];
  for (const [key, list] of byLineWay) {
    const perDay = daily.get(key) ?? 1;
    // Half the time between them over a long service day, between two and fifteen minutes.
    const wait = Math.min(15, Math.max(2, (19 * 60) / perDay / 2));
    for (const order of list.sort((a, b) => b.count - a.count).slice(0, 4)) {
      patterns.push({ line: order.line, direction: order.direction, destination: order.destination, stops: order.stops, minutes: order.minutes, wait: Math.round(wait * 10) / 10 });
    }
  }

  // Every stop a pattern calls at, with its height.
  const used = [...new Set(patterns.flatMap((p) => p.stops))].filter((code) => stops[code]);
  const found = await heights(used.map((code) => [stops[code][0], stops[code][1]]));
  const kept: Record<string, StopEntry> = {};
  used.forEach((code, i) => { kept[code] = [stops[code][0], stops[code][1], stops[code][2], found[i] ?? null]; });
  return { stops: kept, patterns };
}

// MARK: Searching

/** As far as anyone walks to a stop in a straight line (about 15 minutes on the streets), to change between
 *  stops, the streets' share more than a straight line, walking pace, and minutes a change costs on its own. */
const REACH = 1_300;
const CHANGE_REACH = 300;
const STREETS = 1.25;
const METERS_PER_MINUTE = 80;
const CHANGE_MINUTES = 2;
/** A way with a change shows if it feels no more than this many minutes worse than its first line alone. */
const CHANGE_SLACK = 3;
/** A meter up adds this many seconds; a meter down takes off this many, at most this share of the walk. */
const UP_SECONDS = 10;
const DOWN_SECONDS = 2;
const MOST_DOWN_SHARE = 0.3;

export interface Walk {
  minutes: number;
  /** Meters up (down, below zero), where the heights are known. */
  climb: number | null;
}

function walk(meters: number, from: number | null, to: number | null): Walk & { felt: number } {
  const minutes = Math.max(1, Math.round((meters * STREETS) / METERS_PER_MINUTE));
  const climb = from !== null && to !== null ? Math.round(to - from) : null;
  const extra = climb === null ? 0 : Math.max(climb, 0) * UP_SECONDS / 60 - Math.min(Math.max(-climb, 0) * DOWN_SECONDS / 60, minutes * MOST_DOWN_SHARE);
  return { minutes, climb, felt: minutes + extra };
}

interface Leg {
  pattern: Pattern;
  board: number;
  alight: number;
}

interface Label {
  cost: number;
  legs: Leg[];
  walkBefore: Walk;
  change?: Walk;
}

export interface TripStop { code: string; name: string; lat: number; lon: number }
export interface TripLegOut {
  line: string;
  direction: string;
  destination: string;
  board: TripStop;
  alight: TripStop;
  /** Other lines from the same platform to the same place, as good (the J beside the K, L and M at Church). */
  also: { line: string; direction: string; destination: string; board: TripStop; alight: TripStop }[];
  minutes: number;
}
export interface TripWayOut {
  legs: TripLegOut[];
  walkBefore: Walk;
  change?: Walk;
  walkAfter: Walk;
  /** Minutes as it feels: walks weighed by their hills, waits, rides. */
  felt: number;
}

export function searchTrips(network: Network, from: [number, number], to: [number, number], fromHeight: number | null, toHeight: number | null): TripWayOut[] {
  const place = (code: string) => ({ lat: network.stops[code][0], lon: network.stops[code][1] });
  const height = (code: string) => network.stops[code]?.[3] ?? null;
  const near = (lat: number, lon: number, reach: number) => Object.keys(network.stops)
    .map((code) => ({ code, meters: metersBetween({ lat, lon }, place(code)) })).filter((s) => s.meters <= reach);
  // Walks to the stops around the start, and from those around the end.
  const access = new Map(near(from[0], from[1], REACH).map((s) => [s.code, walk(s.meters, fromHeight, height(s.code))]));
  const egress = new Map(near(to[0], to[1], REACH).map((s) => [s.code, walk(s.meters, height(s.code), toHeight)]));
  if (!access.size || !egress.size) return [];

  const found: Label[] = [];
  const finished = (label: Label, end: string) => {
    const after = egress.get(end)!;
    found.push({ ...label, cost: label.cost + after.felt });
  };
  // One ride: every boarding near the start against every stop near the end, on every pattern.
  const firstRides = new Map<string, Label>();
  for (const pattern of network.patterns) {
    let best: { cost: number; board: number } | null = null;
    for (let j = 0; j < pattern.stops.length; j++) {
      const code = pattern.stops[j];
      if (best) {
        const ride = best.cost + pattern.minutes[j];
        const label: Label = { cost: ride, legs: [{ pattern, board: best.board, alight: j }], walkBefore: access.get(pattern.stops[best.board])! };
        // Where it could end.
        if (egress.has(code)) {
          // Every boarding, not just the best, for ways from different stops (Castro and Church).
          for (let i = 0; i < j; i++) {
            const before = access.get(pattern.stops[i]);
            if (!before) continue;
            finished({ cost: before.felt + pattern.wait + pattern.minutes[j] - pattern.minutes[i], legs: [{ pattern, board: i, alight: j }], walkBefore: before }, code);
          }
        }
        // Where a change could start.
        const kept = firstRides.get(code);
        if (!kept || ride < kept.cost) firstRides.set(code, label);
      }
      const before = access.get(code);
      if (before) {
        const boarding = before.felt + pattern.wait - pattern.minutes[j];
        if (!best || boarding < best.cost) best = { cost: boarding, board: j };
      }
    }
  }
  // A walk to another stop close by (or none), to change.
  const changes = new Map<string, Label>();
  for (const [code, label] of firstRides) {
    if (egress.has(code) && label.cost > 90) continue;
    const here = place(code);
    for (const other of near(here.lat, here.lon, CHANGE_REACH)) {
      const step = other.code === code ? { minutes: 0, climb: 0, felt: 0 } : walk(other.meters, height(code), height(other.code));
      const cost = label.cost + step.felt + CHANGE_MINUTES;
      const kept = changes.get(other.code);
      if (!kept || cost < kept.cost) changes.set(other.code, { ...label, cost, change: { minutes: step.minutes, climb: step.climb } });
    }
  }
  // A second ride, from those.
  for (const pattern of network.patterns) {
    let best: { cost: number; board: number; label: Label } | null = null;
    for (let j = 0; j < pattern.stops.length; j++) {
      const code = pattern.stops[j];
      if (best && egress.has(code) && best.label.legs[0].pattern.line !== pattern.line) {
        finished({ ...best.label, cost: best.cost + pattern.minutes[j], legs: [...best.label.legs, { pattern, board: best.board, alight: j }] }, code);
      }
      const changing = changes.get(code);
      if (changing) {
        const boarding = changing.cost + pattern.wait - pattern.minutes[j];
        if (!best || boarding < best.cost) best = { cost: boarding, board: j, label: changing };
      }
    }
  }
  return choose(found, network, egress);
}

/** The ways to show: for each first line, the best from a few different places to get on (a few blocks
 *  apart); a second ride only where it beats riding the first line as far as it goes; then rides from the
 *  same platform to the same place as one way (the lines of Church). The quickest as they feel first. */
function choose(found: Label[], network: Network, egress: Map<string, Walk & { felt: number }>): TripWayOut[] {
  const stop = (code: string): TripStop => ({ code, name: network.stops[code][2], lat: network.stops[code][0], lon: network.stops[code][1] });
  const at = (leg: Leg, end: "board" | "alight") => leg.pattern.stops[end === "board" ? leg.board : leg.alight];
  const apart = (a: string, b: string, meters: number) => metersBetween(stop(a), stop(b)) > meters;
  // Muni's stand-ins for a line early or late at night (the N's NBUS and NOWL), where the line runs too:
  // only in the way of the line itself.
  const lines = new Set(network.patterns.map((p) => p.line));
  const standIn = (line: string) => /^(.+?)(BUS|OWL)$/.test(line) && lines.has(line.replace(/(BUS|OWL)$/, ""));
  const sorted = found.filter((label) => !label.legs.some((leg) => standIn(leg.pattern.line))).sort((a, b) => a.cost - b.cost);
  const kept: Label[] = [];
  const bestDirect = new Map<string, number>();
  const directs: Label[] = [];
  for (const label of sorted) {
    const first = label.legs[0];
    const lineKey = label.legs.map((l) => l.pattern.line).join(">");
    if (label.legs.length === 1) directs.push(label);
    if (label.legs.length === 1) bestDirect.set(first.pattern.line, Math.min(bestDirect.get(first.pattern.line) ?? Infinity, label.cost));
    // A change only where it's worth it: about as quick as the first line alone (less walking, say, for a
    // wait), if that gets there at all. Live times on the trip page settle a near thing.
    if (label.legs.length === 2 && label.cost > (bestDirect.get(first.pattern.line) ?? Infinity) + CHANGE_SLACK) continue;
    // Nor a hop to the second line's own platform (the 5 one stop down Market to the subway): it has to
    // beat walking there and riding from that platform alone.
    if (label.legs.length === 2 && directs.some((d) => d.cost <= label.cost + 1 && !apart(at(d.legs[0], "board"), at(label.legs[1], "board"), CHANGE_REACH))) continue;
    const same = kept.filter((k) => k.legs.map((l) => l.pattern.line).join(">") === lineKey);
    if (same.length >= 3) continue;
    if (same.some((k) => !apart(at(k.legs[0], "board"), at(first, "board"), 400))) continue;
    kept.push(label);
    if (kept.length >= 60) break;
  }
  // One ride from (nearly) the same platform to (nearly) the same place: one way, the others in `also`.
  const ways: TripWayOut[] = [];
  const grouped = new Set<Label>();
  for (const label of kept) {
    if (grouped.has(label)) continue;
    const legs: TripLegOut[] = label.legs.map((leg) => ({
      line: leg.pattern.line, direction: leg.pattern.direction, destination: leg.pattern.destination,
      board: stop(at(leg, "board")), alight: stop(at(leg, "alight")), also: [],
      minutes: Math.round(leg.pattern.minutes[leg.alight] - leg.pattern.minutes[leg.board]),
    }));
    // With a change: any other line from the first platform to the change (the K and M as well as the S),
    // from the network itself, as the search keeps only the quickest to each change.
    if (label.legs.length === 2) {
      const first = label.legs[0];
      const board = at(first, "board"), change = at(first, "alight");
      for (const pattern of network.patterns) {
        if (pattern.line === first.pattern.line || standIn(pattern.line) || legs[0].also.some((a) => a.line === pattern.line)) continue;
        if (pattern.wait > Math.max(first.pattern.wait * 2, 8)) continue;
        const i = pattern.stops.findIndex((code) => !apart(code, board, 150));
        const j = i < 0 ? -1 : pattern.stops.findIndex((code, n) => n > i && !apart(code, change, 150));
        if (j < 0) continue;
        // Not a slower line on the street above (the F over the subway): about as quick as the first.
        if (pattern.minutes[j] - pattern.minutes[i] > legs[0].minutes + 2) continue;
        legs[0].also.push({ line: pattern.line, direction: pattern.direction, destination: pattern.destination,
                            board: stop(pattern.stops[i]), alight: stop(pattern.stops[j]) });
      }
    }
    // With a change: the same first ride, and another line from the second platform to the same place.
    if (label.legs.length === 2) {
      const [first, second] = label.legs;
      for (const other of kept) {
        if (other === label || grouped.has(other) || other.legs.length !== 2) continue;
        const [f, o] = other.legs;
        if (f.pattern.line !== first.pattern.line || at(f, "board") !== at(first, "board")) continue;
        if (o.pattern.line === second.pattern.line || legs[1].also.some((a) => a.line === o.pattern.line)) continue;
        if (apart(at(o, "board"), at(second, "board"), 250) || apart(at(o, "alight"), at(second, "alight"), 400) || other.cost > label.cost + 8) continue;
        if (o.pattern.wait > Math.max(second.pattern.wait * 2, 8)) continue;
        legs[1].also.push({ line: o.pattern.line, direction: o.pattern.direction, destination: o.pattern.destination,
                            board: stop(at(o, "board")), alight: stop(at(o, "alight")) });
        grouped.add(other);
      }
    }
    if (label.legs.length === 1) {
      const leg = label.legs[0];
      for (const other of kept) {
        if (other === label || grouped.has(other) || other.legs.length !== 1) continue;
        const o = other.legs[0];
        if (o.pattern.line === leg.pattern.line || legs[0].also.some((a) => a.line === o.pattern.line)) continue;
        // Not one that hardly runs (a night or early-morning stand-in): it'd only stand in the way.
        if (o.pattern.wait > Math.max(leg.pattern.wait * 2, 8)) continue;
        if (apart(at(o, "board"), at(leg, "board"), 250) || apart(at(o, "alight"), at(leg, "alight"), 400) || other.cost > label.cost + 8) continue;
        legs[0].also.push({ line: o.pattern.line, direction: o.pattern.direction, destination: o.pattern.destination,
                            board: stop(at(o, "board")), alight: stop(at(o, "alight")) });
        grouped.add(other);
      }
    }
    const last = label.legs[label.legs.length - 1];
    const after = egress.get(at(last, "alight"))!;
    ways.push({ legs, walkBefore: label.walkBefore, change: label.change, walkAfter: { minutes: after.minutes, climb: after.climb }, felt: Math.round(label.cost) });
    if (ways.length >= 10) break;
  }
  return ways;
}
