// The stats page, for the app's maker only: /stats (src/stats.html) and /stats/data, its numbers, both
// behind a password (HTTP Basic, any user name, STATS_PASSWORD). The numbers come from the proxy's usage
// events in Workers Analytics Engine (see recordUsage in proxy/src/index.ts), asked with ANALYTICS_TOKEN,
// a Cloudflare API token with Account Analytics: Read, like proxy/stats.sh. Nothing here is stored.
//
// The events are per request: blob1 event, blob2 client, blob3 line, blob4 stop, blob6 install ID,
// blob7 app version, blob8 city ("" before there were cities: San Francisco), blob9 the cities the
// install picked, double1 its favorites. Analytics Engine keeps three months, and samples busy days, so
// requests are summed by _sample_interval and installs are close counts, not exact ones.

import page from "./stats.html";
import usMap from "../images/us-map.json";
import { SCREENS } from "./screens";

export interface StatsEnv {
  STATS_PASSWORD?: string;
  ANALYTICS_TOKEN?: string;
}

const ACCOUNT = "5c16a3f67b5851cf42828b7c52ee53e6";
const DATASET = '"37ShadesOfLate"';
/** An install ID, as the app makes them (a lowercase UUID). */
const INSTALL = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
/** San Francisco's events from before there were cities have none. */
const CITY = "if(blob8 = '', 'sf', blob8)";
/** Each city's default stop (City.defaultSelection in the app): the one its page shows before there's a
 *  favorite there, so its departures come from anyone swiping past, not from riders. */
const DEFAULT_STOPS: Record<string, string> = {
  sf: "13254", seattle: "1_2260", nyc: "G29S", boston: "70076", chicago: "30234", dc: "PF_A03_2", la: "80203",
};
/** An install asking about a city: for the departures of a stop there other than its default, or a
 *  widget showing one (widgets show only favorites). Not loading its lines or map, which swiping past does. */
const USES_CITY = `blob1 = 'departures' AND (blob2 IN ('widget', 'lockscreen') OR NOT (${
  Object.entries(DEFAULT_STOPS).map(([city, stop]) => `(${CITY} = '${city}' AND blob4 = '${stop}')`).join(" OR ")}))`;

export async function handleStats(request: Request, url: URL, env: StatsEnv): Promise<Response> {
  if (!env.STATS_PASSWORD || !env.ANALYTICS_TOKEN) return text("Stats aren't set up: STATS_PASSWORD and ANALYTICS_TOKEN.", 503);
  if (!(await authorized(request, env.STATS_PASSWORD))) {
    return new Response("Members of the 37 only.", { status: 401, headers: { ...PRIVATE, "WWW-Authenticate": 'Basic realm="37 stats", charset="UTF-8"' } });
  }
  // Pictures of the app's screens, for the journey (screens.ts).
  const screen = url.pathname.match(/^\/stats\/screens\/([a-z.]+)\.jpg$/)?.[1];
  if (screen) {
    const picture = SCREENS[screen];
    return picture ? new Response(picture, { headers: { ...PRIVATE, "Content-Type": "image/jpeg", "Cache-Control": "private, max-age=86400" } }) : text("No such screen.", 404);
  }
  if (url.pathname === "/stats/data") {
    const days = [7, 30, 90].includes(Number(url.searchParams.get("days"))) ? Number(url.searchParams.get("days")) : 30;
    // Installs to leave out (the maker's own): install IDs only, so nothing else gets into the query.
    const exclude = (url.searchParams.get("exclude") ?? "").split(",").filter((id) => INSTALL.test(id)).slice(0, 50);
    // The maker's own builds from Xcode, which are left out unless asked for (to try the journey out).
    const debug = url.searchParams.get("debug") === "1";
    try {
      return new Response(JSON.stringify(await numbers(days, exclude, debug, env.ANALYTICS_TOKEN)), { headers: { ...PRIVATE, "Content-Type": "application/json" } });
    } catch (error) {
      return text(`Analytics Engine: ${(error as Error).message}`, 502);
    }
  }
  return new Response((page as string).replace("{{US_MAP}}", JSON.stringify(usMap)), { headers: { ...PRIVATE, "Content-Type": "text/html; charset=utf-8" } });
}

const PRIVATE = { "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow", "X-Frame-Options": "DENY" };
const text = (body: string, status: number) => new Response(body, { status, headers: { ...PRIVATE, "Content-Type": "text/plain" } });

/** Whether the request carries the password, compared without telling by how long it takes. */
async function authorized(request: Request, password: string): Promise<boolean> {
  const header = request.headers.get("Authorization") ?? "";
  if (!header.startsWith("Basic ")) return false;
  let given = "";
  try { given = atob(header.slice(6)).split(":").slice(1).join(":"); } catch { return false; }
  const digest = async (s: string) => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  const [a, b] = await Promise.all([digest(given), digest(password)]);
  return a.reduce((diff, byte, i) => diff | (byte ^ b[i]), 0) === 0;
}

async function numbers(days: number, exclude: string[], debug: boolean, token: string) {
  // App use only: no test runs, nor the installs left out. (Watches carry no install, so they stay.)
  const others = exclude.length ? ` AND blob6 NOT IN (${exclude.map((id) => `'${id}'`).join(", ")})` : "";
  // Not the maker's own builds from Xcode either ("debug"), unless asked for, nor test runs.
  const app = debug ? "blob7 != 'test'" : "blob7 != 'test' AND blob7 != 'debug'";
  const where = `timestamp > NOW() - INTERVAL '${days}' DAY AND ${app}${others}`;
  // Requests to the proxy: not the watches it counts, nor the journey the app sends along with them.
  const requests = `${where} AND blob1 NOT IN ('watch', 'ux')`;
  // Each install's use of each city, over `window`: the page counts it as using one when it came back to
  // it, asking on two days or more, or keeps a widget of it (trying a stop once, in the picker, doesn't).
  const uses = (window: string) => `SELECT blob6 AS install, ${CITY} AS city, min(toDate(timestamp)) AS first,
      count(DISTINCT toDate(timestamp)) AS days, sum(if(blob2 IN ('widget', 'lockscreen'), 1, 0)) AS widgets,
      SUM(_sample_interval) AS requests
    FROM ${DATASET} WHERE ${window} AND ${app} AND blob6 != 'unknown' AND ${USES_CITY}${others}
    GROUP BY install, city`;
  const range = `timestamp > NOW() - INTERVAL '${days}' DAY`;
  const queries = {
    // How people get around the app (see recordJourney in the proxy): every event, in order, for the page
    // to follow each session through. When it happened is double3; the timestamp is when it arrived.
    journey: `SELECT blob2 AS kind, blob3 AS name, blob4 AS detail, blob5 AS came, blob6 AS install, blob7 AS version,
                     blob8 AS city, blob9 AS session, double2 AS seconds, double3 AS at, double4 AS seq
               FROM ${DATASET} WHERE ${where} AND blob1 = 'ux' ORDER BY at, seq LIMIT 20000`,
    summary: `SELECT count(DISTINCT blob6) AS installs, SUM(_sample_interval) AS requests
              FROM ${DATASET} WHERE ${requests} AND blob6 != 'unknown'`,
    daily: `SELECT toDate(timestamp) AS day, count(DISTINCT blob6) AS installs, SUM(_sample_interval) AS requests
            FROM ${DATASET} WHERE ${requests} AND blob6 != 'unknown' GROUP BY day ORDER BY day`,
    // When each install was first seen, over all Analytics Engine keeps (new installs per day), and when it
    // first used each city (the map's growth).
    seen: `SELECT blob6 AS install, min(toDate(timestamp)) AS first
           FROM ${DATASET} WHERE timestamp > NOW() - INTERVAL '92' DAY AND ${app} AND blob1 NOT IN ('watch', 'ux') AND blob6 != 'unknown'${others}
           GROUP BY install`,
    firsts: uses("timestamp > NOW() - INTERVAL '92' DAY"),
    uses: uses(range),
    clients: `SELECT blob2 AS client, count(DISTINCT blob6) AS installs, SUM(_sample_interval) AS requests
              FROM ${DATASET} WHERE ${requests} GROUP BY client ORDER BY requests DESC`,
    watches: `SELECT toDate(timestamp) AS day, blob8 AS city, SUM(_sample_interval) AS watches
              FROM ${DATASET} WHERE ${where} AND blob1 = 'watch' GROUP BY day, city ORDER BY day`,
    top: `SELECT blob6 AS install, SUM(_sample_interval) AS requests, count(DISTINCT toDate(timestamp)) AS days,
                 count(DISTINCT ${CITY}) AS cities, max(double1) AS favorites, argMax(blob7, timestamp) AS version, max(timestamp) AS last
          FROM ${DATASET} WHERE ${requests} AND blob6 != 'unknown' GROUP BY install ORDER BY requests DESC LIMIT 15`,
    picked: `SELECT blob9 AS cities, count(DISTINCT blob6) AS installs
             FROM ${DATASET} WHERE ${requests} AND blob9 != '' GROUP BY cities ORDER BY installs DESC LIMIT 12`,
    versions: `SELECT blob7 AS version, count(DISTINCT blob6) AS installs
               FROM ${DATASET} WHERE ${requests} AND blob7 != '' GROUP BY version ORDER BY installs DESC LIMIT 8`,
    hours: `SELECT toHour(timestamp) AS hour, SUM(_sample_interval) AS requests
            FROM ${DATASET} WHERE ${requests} GROUP BY hour ORDER BY hour`,
    lines: `SELECT ${CITY} AS city, blob3 AS line, count(DISTINCT blob6) AS installs, SUM(_sample_interval) AS requests
            FROM ${DATASET} WHERE ${requests} AND blob1 = 'departures' AND blob3 != ''
            GROUP BY city, line ORDER BY installs DESC, requests DESC LIMIT 12`,
    favorites: `SELECT favorites, count() AS installs FROM (
                  SELECT blob6, max(double1) AS favorites FROM ${DATASET} WHERE ${requests} AND blob6 != 'unknown' GROUP BY blob6)
                GROUP BY favorites ORDER BY favorites`,
  };
  const entries = await Promise.all(Object.entries(queries).map(async ([name, sql]) => [name, await query(sql, token)] as const));
  return { days, excluded: exclude.length, asOf: new Date().toISOString(), ...Object.fromEntries(entries) };
}

async function query(sql: string, token: string): Promise<Record<string, unknown>[]> {
  const response = await fetch(`https://api.cloudflare.com/client/v4/accounts/${ACCOUNT}/analytics_engine/sql`, {
    method: "POST", headers: { Authorization: `Bearer ${token}` }, body: `${sql} FORMAT JSON`,
  });
  const body = await response.text();
  if (!response.ok) throw new Error(`${response.status} ${body.slice(0, 200)}`);
  return (JSON.parse(body) as { data: Record<string, unknown>[] }).data;
}
