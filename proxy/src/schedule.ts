import { eachZipRow, parseCSV, readZipEntry } from "./geo";

/** A line calling at a stop, as the schedule has it: its id (route_short_name, as 511 names lines),
 *  IB or OB, and where it's headed. */
export interface ScheduledLine {
  line: string;
  direction: string;
  destination: string;
}

/**
 * Which lines call at which stops (by stop code), from a GTFS feed: every line that's scheduled to,
 * whether or not a bus is coming just now. The live times only know the lines with a bus on the
 * way, which leaves a stop bare late at night or between runs. stop_times.txt is read as it's
 * unzipped, a row at a time; only one of each stop, line and direction is kept.
 */
export async function scheduledLines(zip: ArrayBuffer): Promise<Record<string, ScheduledLine[]>> {
  const [routesText, tripsText, stopsText, directionsText] = await Promise.all(
    ["routes.txt", "trips.txt", "stops.txt", "directions.txt"].map((name) => readZipEntry(zip, name)));
  if (!routesText || !tripsText || !stopsText) throw new Error("GTFS feed without routes, trips or stops");
  const lineOf = new Map(parseCSV(routesText).map((r) => [r.route_id, r.route_short_name || r.route_id]));
  // Muni's direction_id 0 is outbound and 1 inbound; directions.txt says so for each route, where there is one.
  const wayOf = new Map((directionsText ? parseCSV(directionsText) : []).map((d) => [`${d.route_id}|${d.direction_id}`,
    /^in/i.test(d.direction) ? "IB" : /^out/i.test(d.direction) ? "OB" : d.direction]));
  const way = (route: string, id: string) => wayOf.get(`${route}|${id}`) ?? (id === "1" ? "IB" : "OB");
  const codeOf = new Map(parseCSV(stopsText).map((s) => [s.stop_id, s.stop_code || s.stop_id]));
  // Each trip as the line, way and destination it serves: an index into `kinds`.
  const kinds: ScheduledLine[] = [];
  const kindIndex = new Map<string, number>();
  const tripKind = new Map<string, number>();
  for (const trip of parseCSV(tripsText)) {
    const line = lineOf.get(trip.route_id);
    if (!line) continue;
    const kind: ScheduledLine = { line, direction: way(trip.route_id, trip.direction_id), destination: trip.trip_headsign ?? "" };
    const key = `${kind.line}|${kind.direction}|${kind.destination}`;
    let index = kindIndex.get(key);
    if (index === undefined) { index = kinds.length; kinds.push(kind); kindIndex.set(key, index); }
    tripKind.set(trip.trip_id, index);
  }
  const seen = new Set<string>();
  const atStop: Record<string, ScheduledLine[]> = {};
  let tripColumn = 0, stopColumn = 3;
  const read = await eachZipRow(zip, "stop_times.txt", (columns) => {
    tripColumn = columns.indexOf("trip_id");
    stopColumn = columns.indexOf("stop_id");
  }, (fields) => {
    const kind = tripKind.get(fields[tripColumn]);
    if (kind === undefined) return;
    const stop = fields[stopColumn];
    const key = `${stop}|${kind}`;
    if (seen.has(key)) return;
    seen.add(key);
    const code = codeOf.get(stop) ?? stop;
    const found = kinds[kind];
    // One destination per line and way at a stop (the first the schedule has; short runs after).
    if (!(atStop[code] ??= []).some((l) => l.line === found.line && l.direction === found.direction)) atStop[code].push(found);
  });
  if (!read) throw new Error("GTFS feed without stop_times");
  return atStop;
}
