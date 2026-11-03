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
  const [routesText, directionsText] = await Promise.all(["routes.txt", "directions.txt"].map((name) => readZipEntry(zip, name)));
  if (!routesText) throw new Error("GTFS feed without routes");
  const lineOf = new Map(parseCSV(routesText).map((r) => [r.route_id, r.route_short_name || r.route_id]));
  // Muni's direction_id 0 is outbound and 1 inbound; directions.txt says so for each route, where there is one.
  const wayOf = new Map((directionsText ? parseCSV(directionsText) : []).map((d) => [`${d.route_id}|${d.direction_id}`,
    /^in/i.test(d.direction) ? "IB" : /^out/i.test(d.direction) ? "OB" : d.direction]));
  const way = (route: string, id: string) => wayOf.get(`${route}|${id}`) ?? (id === "1" ? "IB" : "OB");
  // The big files a row at a time, keeping only the columns needed: a whole feed parsed at once is more
  // than a Worker's memory has room for.
  const column = (columns: string[], name: string) => columns.indexOf(name);
  const codeOf = new Map<string, string>();
  let stopID = 0, stopCode = -1;
  const stopsRead = await eachZipRow(zip, "stops.txt", (c) => { stopID = column(c, "stop_id"); stopCode = column(c, "stop_code"); },
    (f) => { codeOf.set(f[stopID], (stopCode >= 0 && f[stopCode]) || f[stopID]); });
  // Each trip as the line, way and destination it serves: an index into `kinds`.
  const kinds: ScheduledLine[] = [];
  const kindIndex = new Map<string, number>();
  const tripKind = new Map<string, number>();
  let route = 0, trip = 2, direction = 4, headsign = 3;
  const tripsRead = await eachZipRow(zip, "trips.txt", (c) => {
    route = column(c, "route_id"); trip = column(c, "trip_id"); direction = column(c, "direction_id"); headsign = column(c, "trip_headsign");
  }, (f) => {
    const line = lineOf.get(f[route]);
    if (!line) return;
    const destination = (f[headsign] ?? "").replace(/^"|"$/g, "");
    const key = `${line}|${way(f[route], f[direction])}|${destination}`;
    let index = kindIndex.get(key);
    if (index === undefined) {
      index = kinds.length;
      kinds.push({ line, direction: way(f[route], f[direction]), destination });
      kindIndex.set(key, index);
    }
    tripKind.set(f[trip], index);
  });
  if (!stopsRead || !tripsRead) throw new Error("GTFS feed without stops or trips");
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
