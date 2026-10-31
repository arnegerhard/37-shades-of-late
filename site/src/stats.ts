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
  /** The app's journeys, as the proxy stores them (proxy/migrations). */
  JOURNEYS?: D1Database;
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
  if (url.pathname === "/stats/live" || url.pathname === "/stats/live/user") {
    if (!env.JOURNEYS) return text("No journeys database.", 503);
    const exclude = (url.searchParams.get("exclude") ?? "").split(",").filter((id) => INSTALL.test(id)).slice(0, 50);
    const debug = url.searchParams.get("debug") === "1";
    const body = url.pathname === "/stats/live"
      ? await live(env.JOURNEYS, exclude, debug)
      : await liveUser(env.JOURNEYS, url.searchParams.get("id") ?? "", Number(url.searchParams.get("after")) || 0);
    return new Response(JSON.stringify(body), { headers: { ...PRIVATE, "Content-Type": "application/json" } });
  }
  if (url.pathname === "/stats/data") {
    const days = [7, 30, 90].includes(Number(url.searchParams.get("days"))) ? Number(url.searchParams.get("days")) : 30;
    // Installs to leave out (the maker's own): install IDs only, so nothing else gets into the query.
    const exclude = (url.searchParams.get("exclude") ?? "").split(",").filter((id) => INSTALL.test(id)).slice(0, 50);
    // The maker's own builds from Xcode, which are left out unless asked for (to try the journey out).
    const debug = url.searchParams.get("debug") === "1";
    try {
      return new Response(JSON.stringify(await numbers(days, exclude, debug, env.ANALYTICS_TOKEN, env.JOURNEYS)), { headers: { ...PRIVATE, "Content-Type": "application/json" } });
    } catch (error) {
      return text(`Analytics Engine: ${(error as Error).message}`, 502);
    }
  }
  return new Response((page as string).replace("{{US_MAP}}", JSON.stringify(usMap)).replace("{{SCREENS_VERSION}}", screensVersion()), { headers: { ...PRIVATE, "Content-Type": "text/html; charset=utf-8" } });
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

async function numbers(days: number, exclude: string[], debug: boolean, token: string, journeys?: D1Database) {
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
  const [entries, journey, spreaders] = await Promise.all([
    Promise.all(Object.entries(queries).map(async ([name, sql]) => [name, await query(sql, token)] as const)),
    journeyOf(days, exclude, debug, journeys),
    spreadersOf(days, exclude, debug, journeys),
  ]);
  return { days, excluded: exclude.length, asOf: new Date().toISOString(), journey, spreaders, ...Object.fromEntries(entries) };
}

/** A short hash of the screens' pictures (FNV-1a), so the page's addresses for them change when they do. */
let screensHash: string | undefined;
function screensVersion(): string {
  if (screensHash) return screensHash;
  let hash = 0x811c9dc5;
  for (const id of Object.keys(SCREENS).sort()) {
    for (const byte of new Uint8Array(SCREENS[id])) hash = Math.imul(hash ^ byte, 0x01000193);
  }
  return (screensHash = (hash >>> 0).toString(36));
}

/** An install is live while its app is in front: asking within this many seconds, and not put away since. */
const LIVE_SECONDS = 150;

/** Who's around (the presence the proxy keeps, see recordPresence): every install seen in the last day,
 *  live or not, with the screen it was last on, for the live view's map and lists. */
async function live(db: D1Database, exclude: string[], debug: boolean) {
  const now = Math.floor(Date.now() / 1000), since = now - 86_400;
  const conditions = ["p.last_seen > ?1", "p.version != 'test'", ...(debug ? [] : ["p.version != 'debug'"]),
                      ...(exclude.length ? [`p.install NOT IN (${exclude.map((_, i) => `?${i + 3}`).join(", ")})`] : [])];
  const { results } = await db.prepare(`
      SELECT p.install, p.city, p.version, p.favorites, p.first_seen, p.last_seen, p.last_app, p.last_widget, p.away, p.place, p.lat, p.lon,
             (p.last_app > ?2 AND p.last_app > p.away) AS live, s.name AS screen, s.at AS screen_at
      FROM presence p LEFT JOIN (
        SELECT install, name, at FROM (
          SELECT install, name, at, ROW_NUMBER() OVER (PARTITION BY install ORDER BY at DESC, seq DESC) AS r
          FROM events WHERE kind = 'screen' AND at > ?1) WHERE r = 1) s ON s.install = p.install
      WHERE ${conditions.join(" AND ")} ORDER BY live DESC, p.last_seen DESC LIMIT 1000`)
    .bind(since, now - LIVE_SECONDS, ...exclude).all();
  return { now, liveSeconds: LIVE_SECONDS, users: results };
}

/** One install, as it goes: its presence, and its events stored after `after` (its last 150, first time). Counted
 *  by the order they were stored (rowid): app builds before 1.1 number their events again every launch. */
async function liveUser(db: D1Database, install: string, after: number) {
  if (!INSTALL.test(install)) return { error: "no such install" };
  const now = Math.floor(Date.now() / 1000);
  const [presence, events] = await Promise.all([
    db.prepare(`SELECT *, (last_app > ?2 AND last_app > away) AS live FROM presence WHERE install = ?1`).bind(install, now - LIVE_SECONDS).first(),
    after
      ? db.prepare(`SELECT rowid AS id, seq, at, arrived, kind, name, detail, came, session, city, seconds FROM events WHERE install = ?1 AND rowid > ?2 ORDER BY at, rowid`).bind(install, after).all()
      : db.prepare(`SELECT * FROM (SELECT rowid AS id, seq, at, arrived, kind, name, detail, came, session, city, seconds FROM events WHERE install = ?1 ORDER BY rowid DESC LIMIT 150) ORDER BY at, id`).bind(install).all(),
  ]);
  return { now, presence, events: events.results };
}

/**
 * Who spreads the app, over `days`: per install with a share code (presence.share_code), the links it
 * sent (share.send taps), how often its links were opened on the website (link_opens, counted by the
 * site) and in others' apps (link.open, whose detail is "code [qr] [new]"), how often that added the
 * stop, and how many of those opening it in the app were new installs then (brought in, most likely).
 */
async function spreadersOf(days: number, exclude: string[], debug: boolean, journeys?: D1Database) {
  if (!journeys) return [];
  const since = Math.floor(Date.now() / 1000) - days * 86_400;
  const sinceDay = new Date(since * 1000).toISOString().slice(0, 10);
  const owners = ["p.share_code != ''", "p.version != 'test'", ...(debug ? [] : ["p.version != 'debug'"]),
                  ...(exclude.length ? [`p.install NOT IN (${exclude.map((_, i) => `?${i + 3}`).join(", ")})`] : [])];
  const recipients = debug ? "" : "AND e.version != 'debug'";
  const { results } = await journeys.prepare(`
      WITH sent AS (
        SELECT install, count(*) AS sent, sum(detail = 'qr' OR detail LIKE 'qr, %') AS sent_qr FROM events
        WHERE kind = 'tap' AND name = 'share.send' AND at > ?1 GROUP BY install),
      web AS (
        SELECT code, sum(opens) AS web, sum(CASE WHEN qr = 1 THEN opens ELSE 0 END) AS web_qr FROM link_opens
        WHERE day >= ?2 GROUP BY code),
      app AS (
        SELECT substr(e.detail, 1, 6) AS code, e.install, max(e.name = 'link.open') AS opened, max(e.name = 'link.add') AS added,
               max(e.detail LIKE '% new') AS new, max(e.detail LIKE '% qr%') AS qr
        FROM events e WHERE e.kind = 'tap' AND e.name IN ('link.open', 'link.add') AND length(e.detail) >= 6 AND e.at > ?1 ${recipients}
        GROUP BY code, e.install)
      SELECT p.install, p.share_code AS code, p.city, p.place, p.version,
             coalesce(s.sent, 0) AS sent, coalesce(s.sent_qr, 0) AS sent_qr,
             coalesce(w.web, 0) AS web, coalesce(w.web_qr, 0) AS web_qr,
             (SELECT count(*) FROM app a WHERE a.code = p.share_code AND a.install != p.install AND a.opened) AS opened,
             (SELECT count(*) FROM app a WHERE a.code = p.share_code AND a.install != p.install AND a.qr) AS opened_qr,
             (SELECT count(*) FROM app a WHERE a.code = p.share_code AND a.install != p.install AND a.added) AS added,
             (SELECT count(*) FROM app a WHERE a.code = p.share_code AND a.install != p.install AND a.new) AS brought
      FROM presence p LEFT JOIN sent s ON s.install = p.install LEFT JOIN web w ON w.code = p.share_code
      WHERE ${owners.join(" AND ")}`)
    .bind(since, sinceDay, ...exclude).all();
  return results.filter((r) => Number(r.sent) || Number(r.web) || Number(r.opened))
    .sort((a, b) => Number(b.brought) - Number(a.brought) || Number(b.added) - Number(a.added)
      || Number(b.opened) + Number(b.web) - Number(a.opened) - Number(a.web) || Number(b.sent) - Number(a.sent))
    .slice(0, 50);
}

/** How people get around the app (see recordJourney in the proxy): every event over `days`, in order, for
 *  the page to follow each session through. From D1, which keeps them all (Analytics Engine samples). */
async function journeyOf(days: number, exclude: string[], debug: boolean, journeys?: D1Database) {
  if (!journeys) return [];
  const since = Math.floor(Date.now() / 1000) - days * 86_400;
  const conditions = ["at > ?", "version != 'test'", ...(debug ? [] : ["version != 'debug'"]),
                      ...(exclude.length ? [`install NOT IN (${exclude.map(() => "?").join(", ")})`] : [])];
  const { results } = await journeys.prepare(`SELECT kind, name, detail, came, install, version, city, session, seconds, at, seq
      FROM events WHERE ${conditions.join(" AND ")} ORDER BY at, seq LIMIT 100000`).bind(since, ...exclude).all();
  return results;
}

async function query(sql: string, token: string): Promise<Record<string, unknown>[]> {
  const response = await fetch(`https://api.cloudflare.com/client/v4/accounts/${ACCOUNT}/analytics_engine/sql`, {
    method: "POST", headers: { Authorization: `Bearer ${token}` }, body: `${sql} FORMAT JSON`,
  });
  const body = await response.text();
  if (!response.ok) throw new Error(`${response.status} ${body.slice(0, 200)}`);
  return (JSON.parse(body) as { data: Record<string, unknown>[] }).data;
}
