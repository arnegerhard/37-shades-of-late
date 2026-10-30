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

export interface StatsEnv {
  STATS_PASSWORD?: string;
  ANALYTICS_TOKEN?: string;
}

const ACCOUNT = "5c16a3f67b5851cf42828b7c52ee53e6";
const DATASET = '"37ShadesOfLate"';
/** San Francisco's events from before there were cities have none. */
const CITY = "if(blob8 = '', 'sf', blob8)";

export async function handleStats(request: Request, url: URL, env: StatsEnv): Promise<Response> {
  if (!env.STATS_PASSWORD || !env.ANALYTICS_TOKEN) return text("Stats aren't set up: STATS_PASSWORD and ANALYTICS_TOKEN.", 503);
  if (!(await authorized(request, env.STATS_PASSWORD))) {
    return new Response("Members of the 37 only.", { status: 401, headers: { ...PRIVATE, "WWW-Authenticate": 'Basic realm="37 stats", charset="UTF-8"' } });
  }
  if (url.pathname === "/stats/data") {
    const days = [7, 30, 90].includes(Number(url.searchParams.get("days"))) ? Number(url.searchParams.get("days")) : 30;
    try {
      return new Response(JSON.stringify(await numbers(days, env.ANALYTICS_TOKEN)), { headers: { ...PRIVATE, "Content-Type": "application/json" } });
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

async function numbers(days: number, token: string) {
  // App use only: no test runs, and not the server's own requests.
  const where = `timestamp > NOW() - INTERVAL '${days}' DAY AND blob7 != 'test'`;
  const requests = `${where} AND blob1 != 'watch'`;
  const queries = {
    summary: `SELECT count(DISTINCT blob6) AS installs, SUM(_sample_interval) AS requests
              FROM ${DATASET} WHERE ${requests} AND blob6 != 'unknown'`,
    daily: `SELECT toDate(timestamp) AS day, count(DISTINCT blob6) AS installs, SUM(_sample_interval) AS requests
            FROM ${DATASET} WHERE ${requests} AND blob6 != 'unknown' GROUP BY day ORDER BY day`,
    // When each install was first seen in each city, over all Analytics Engine keeps: the map's growth,
    // and new installs per day.
    firsts: `SELECT blob6 AS install, ${CITY} AS city, min(toDate(timestamp)) AS first
             FROM ${DATASET} WHERE timestamp > NOW() - INTERVAL '92' DAY AND blob7 != 'test' AND blob1 != 'watch' AND blob6 != 'unknown'
             GROUP BY install, city`,
    cityDaily: `SELECT toDate(timestamp) AS day, ${CITY} AS city, count(DISTINCT blob6) AS installs
                FROM ${DATASET} WHERE ${requests} AND blob6 != 'unknown' GROUP BY day, city`,
    cities: `SELECT ${CITY} AS city, count(DISTINCT blob6) AS installs, SUM(_sample_interval) AS requests
             FROM ${DATASET} WHERE ${requests} GROUP BY city ORDER BY installs DESC`,
    clients: `SELECT blob2 AS client, count(DISTINCT blob6) AS installs, SUM(_sample_interval) AS requests
              FROM ${DATASET} WHERE ${requests} GROUP BY client ORDER BY requests DESC`,
    watches: `SELECT toDate(timestamp) AS day, blob8 AS city, SUM(_sample_interval) AS watches
              FROM ${DATASET} WHERE ${where} AND blob1 = 'watch' GROUP BY day, city ORDER BY day`,
    top: `SELECT blob6 AS install, SUM(_sample_interval) AS requests, count(DISTINCT toDate(timestamp)) AS days,
                 count(DISTINCT ${CITY}) AS cities, max(double1) AS favorites, argMax(blob7, timestamp) AS version, max(timestamp) AS last
          FROM ${DATASET} WHERE ${requests} AND blob6 != 'unknown' GROUP BY install ORDER BY requests DESC LIMIT 15`,
    citiesUsed: `SELECT used, count() AS installs FROM (
                   SELECT blob6, count(DISTINCT ${CITY}) AS used FROM ${DATASET}
                   WHERE ${requests} AND blob1 = 'departures' AND blob6 != 'unknown' GROUP BY blob6)
                 GROUP BY used ORDER BY used`,
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
  return { days, asOf: new Date().toISOString(), ...Object.fromEntries(entries) };
}

async function query(sql: string, token: string): Promise<Record<string, unknown>[]> {
  const response = await fetch(`https://api.cloudflare.com/client/v4/accounts/${ACCOUNT}/analytics_engine/sql`, {
    method: "POST", headers: { Authorization: `Bearer ${token}` }, body: `${sql} FORMAT JSON`,
  });
  const body = await response.text();
  if (!response.ok) throw new Error(`${response.status} ${body.slice(0, 200)}`);
  return (JSON.parse(body) as { data: Record<string, unknown>[] }).data;
}
