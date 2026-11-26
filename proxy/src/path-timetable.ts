/**
 * PATH's timetable, for the trains after the ones the RidePATH feed lists (only the next train of each line at
 * each station; see nyc.ts). Read once a day from the Port Authority's own schedule pages, weekday and weekend:
 * their content comes as JSON (the pages draw it in the browser), each line's timetable one way an HTML table with
 * a column per station ("Grove St Departure", ..., "Arrival at WTC") and a row per train ("10:50 PM").
 *
 * Until those can be had, and should they ever change shape, last year's timetable from PATH's GTFS stands in
 * (path-schedule.json, from scripts/path-schedule.py): better a train a few minutes off than none.
 *
 * Both as each day type's departures per line and platform, coded as nyc-subway.json's ("PATH-862|PGRVY"): seconds
 * after that day's midnight (past 24 hours for trains after midnight), and the platform the train ends at.
 */

import fallback from "./path-schedule.json";

export type PathDay = "weekday" | "saturday" | "sunday";
export type PathTimetable = Record<PathDay, Record<string, [seconds: number, end: string][]>>;

const PAGES = "https://www.panynj.gov/content/path/en/schedules-maps/";
const TTL_MS = 24 * 3600_000;
const RETRY_MS = 30 * 60_000;

/** Each timetable's title, as the pages have it, as a line's route and way ("Y" to New York, "J" to New Jersey). */
const LINES: [RegExp, string, string][] = [
  [/^Newark - World Trade Center$/, "PATH-862", "Y"], [/^World Trade Center - Newark$/, "PATH-862", "J"],
  [/^Journal Square - 33 Street \(via Hoboken\)$/, "PATH-1024", "Y"], [/^33 Street - Journal Square \(via Hoboken\)$/, "PATH-1024", "J"],
  [/^Journal Square - 33 Street$/, "PATH-861", "Y"], [/^33 Street - Journal Square$/, "PATH-861", "J"],
  [/^Hoboken - 33 Street$/, "PATH-859", "Y"], [/^33 Street - Hoboken$/, "PATH-859", "J"],
  [/^Hoboken - World Trade Center$/, "PATH-860", "Y"], [/^World Trade Center - Hoboken$/, "PATH-860", "J"],
];

/** A column's station, by its heading, as RidePATH codes it. */
const STATIONS: [RegExp, string][] = [
  [/Newark/, "NWK"], [/Harrison/, "HAR"], [/JSQ|Journal/, "JSQ"], [/Grove/, "GRV"], [/Exchange/, "EXP"],
  [/Newport/, "NEW"], [/Hoboken/, "HOB"], [/WTC|World Trade/, "WTC"], [/Chris/, "CHR"], [/\b9 St/, "09S"],
  [/\b14 St/, "14S"], [/\b23 St/, "23S"], [/\b33 St/, "33S"],
];

let cached: { value: Promise<PathTimetable>; at: number } | undefined;

/** The timetable, at most a day old; the stand-in until the pages can be read. */
export function pathTimetable(): Promise<PathTimetable> {
  if (cached && Date.now() - cached.at < TTL_MS) return cached.value;
  const last = cached?.value;
  const value = readPages().catch(async (error) => {
    console.warn(`PATH timetable: ${error}`);
    // Tried again in a while; meanwhile the last one read, else last year's.
    cached = { value: Promise.resolve((await last?.catch(() => undefined)) ?? (fallback as any).days), at: Date.now() - TTL_MS + RETRY_MS };
    return cached.value;
  });
  cached = { value, at: Date.now() };
  return value;
}

async function readPages(): Promise<PathTimetable> {
  const get = async (page: string) => {
    const response = await fetch(`${PAGES}${page}.model.json`, { headers: { "User-Agent": "Mozilla/5.0 (37 Shades of Late; https://37shadesoflate.com)" } });
    if (!response.ok) throw new Error(`${page}: ${response.status}`);
    return response.json() as Promise<any>;
  };
  const [weekday, weekend] = await Promise.all([get("weekday-schedules"), get("weekend-schedules")]);
  const timetable: PathTimetable = { weekday: {}, saturday: {}, sunday: {} };
  // Only the pages' own timetables, not those of the special weekends under them.
  for (const [page, dayOf] of [[weekday, () => "weekday"], [weekend, (title: string) => /Sunday/i.test(title) ? "sunday" : /Saturday/i.test(title) ? "saturday" : undefined]] as const) {
    for (const [name, list] of Object.entries<any>(page?.[":items"]?.root?.[":items"] ?? {})) {
      if (!name.startsWith("accordionlist")) continue;
      const day = dayOf(String(list.title ?? "")) as PathDay | undefined;
      if (!day) continue;
      for (const accordion of Object.values<any>(list[":items"] ?? {})) {
        const title = plain(String(accordion.accordionLabel ?? ""));
        const line = LINES.find(([pattern]) => pattern.test(title));
        const table = tables(accordion)[0];
        if (line && table) readTable(table, line[1], line[2], timetable[day]);
      }
    }
  }
  // Every line both ways, a few platforms each, for each day type: far fewer means the pages changed shape.
  for (const [day, platforms] of Object.entries(timetable)) {
    const count = Object.keys(platforms).length;
    if (count < 20) throw new Error(`only ${count} line platforms read for ${day}`);
  }
  for (const day of Object.values(timetable)) for (const list of Object.values(day)) list.sort((a, b) => a[0] - b[0]);
  return timetable;
}

/** One way of a line: each train's departures from each station but the last, where it ends. */
function readTable(html: string, route: string, way: string, into: Record<string, [number, string][]>) {
  const rows = [...html.matchAll(/<tr[\s\S]*?<\/tr>/g)].map((row) => [...row[0].matchAll(/<td[\s\S]*?<\/td>/g)].map((cell) => plain(cell[0])));
  const heading = rows.find((cells) => cells.some((c) => /Departure|Arrival/.test(c)));
  if (!heading) return;
  const stations = heading.map((c) => STATIONS.find(([pattern]) => pattern.test(c))?.[1]);
  const end = stations.at(-1);
  if (!end || !/Arrival/.test(heading.at(-1)!)) return;
  let previousStart = -1;
  for (const cells of rows) {
    const times = cells.map(seconds);
    const first = times.find((t) => t !== undefined);
    if (first === undefined) continue;
    // A train after midnight at the bottom of the day's timetable is that night's, not the morning's.
    let offset = previousStart - first > 12 * 3600 ? 86400 : 0;
    previousStart = first + offset;
    let last = -1;
    times.forEach((time, i) => {
      if (time === undefined || i === times.length - 1 || !stations[i]) return;
      // Past midnight along the way.
      if (time + offset < last) offset += 86400;
      last = time + offset;
      const key = `${route}|P${stations[i]}${way}`;
      (into[key] ??= []).push([last, `P${end}${way}`]);
    });
  }
}

/** "10:50 PM" as seconds after midnight. */
function seconds(text: string): number | undefined {
  const match = /(\d{1,2}):(\d{2})\s*([AP])\.?M/i.exec(text);
  if (!match) return undefined;
  const hours = (Number(match[1]) % 12) + (match[3].toUpperCase() === "P" ? 12 : 0);
  return hours * 3600 + Number(match[2]) * 60;
}

function plain(html: string): string {
  return html.replace(/<[^>]+>|&nbsp;/g, " ").replace(/\s+/g, " ").trim();
}

/** The HTML tables anywhere in a piece of the page. */
function tables(value: unknown): string[] {
  if (typeof value === "string") return value.includes("<table") ? [value] : [];
  if (value && typeof value === "object") return Object.values(value).flatMap(tables);
  return [];
}
