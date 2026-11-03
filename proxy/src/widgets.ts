import { DurableObject } from "cloudflare:workers";
import { APNs, shard, type APNsEnv } from "./apns";
import proxy from "./index";

/**
 * Widget pushes: a nudge to a phone's widgets (iOS 26 and later) to fetch their departures again,
 * when what they show has gone wrong. A widget fetches when iOS lets it, which on the Lock Screen
 * can be a quarter of an hour or more apart; meanwhile it counts down what it fetched last, which the
 * buses don't keep to. So after every fetch it tells the proxy what it's showing:
 *
 *   POST /v1/widget      {token, environment, city, rows: [{line, stop, direction, shown}], until}: the
 *                        widgets' push token (one for all of an install's widgets), the departures each
 *                        row shows (seconds since 1970, the next few), and when its minutes run out
 *   POST /v1/widget/end  {token}: there are no widgets any more, stop
 *
 * Every two minutes, each object looks at its widgets' stops again (through the proxy's own routes and
 * caches, a stop shared by several looked up once), and pushes to those showing a next bus two
 * minutes or more off (or one gone, or one not there), or about to run out of minutes. iOS budgets
 * widget pushes as it does a widget's own fetches, and takes them when it sees fit, so not too
 * often: ten minutes apart at least, and no more than thirty a day. A widget not heard from in six
 * hours (taken off, the phone off) is forgotten; its next fetch tells the proxy again.
 */

export interface WidgetEnv extends APNsEnv {
  WIDGETS: DurableObjectNamespace<WidgetPushes>;
}

const TOPIC = "info.jetsons.bus37.push-type.widgets";
const CHECK_EVERY_MS = 2 * 60_000;
/** A next departure this far off what the widget shows is worth a push. */
const OFF_BY_SECONDS = 120;
const LEAST_APART_SECONDS = 10 * 60;
const MOST_A_DAY = 30;
const FORGOTTEN_AFTER_SECONDS = 6 * 60 * 60;
const SHARDS = 32;
const MOST_PER_SHARD = 500;
const CITIES = ["sf", "seattle", "nyc", "boston", "chicago", "dc", "la"];

interface Row {
  line: string;
  stop: string;
  direction: string;
  /** The departures the widget shows, seconds since 1970. */
  shown: number[];
}

interface Widgets {
  token: string;
  environment: "sandbox" | "production";
  city: string;
  rows: Row[];
  /** When the widget last said what it shows, and when its minutes run out (seconds since 1970). */
  reportedAt: number;
  until: number;
  pushedAt?: number;
  /** Pushes on `day` (UTC, YYYY-MM-DD), for the daily most. */
  day?: string;
  pushes?: number;
}

/** Hands a widget request to its token's Durable Object. */
export async function handleWidget(request: Request, env: WidgetEnv, path: string): Promise<Response> {
  const body = await request.text();
  let token = "";
  try { token = String(JSON.parse(body)?.token ?? ""); } catch { /* the object turns it away */ }
  const stub = env.WIDGETS.get(env.WIDGETS.idFromName(`widgets-v1-${shard(token, SHARDS)}`));
  return stub.fetch(new Request(`https://widgets${path}`, { method: "POST", body }));
}

export class WidgetPushes extends DurableObject<WidgetEnv> {
  private apns = new APNs(this.env);

  async fetch(request: Request): Promise<Response> {
    const { pathname } = new URL(request.url);
    let body: any;
    try { body = await request.json(); } catch { return reply({ error: "JSON body required" }, 400); }
    const token = String(body?.token ?? "");
    if (!/^[0-9a-f]{16,400}$/.test(token)) return reply({ error: "token (hex) is required" }, 400);

    if (pathname === "/v1/widget/end") {
      await this.ctx.storage.delete(`w:${token}`);
      return reply({ ok: true });
    }

    const now = Date.now() / 1000;
    const rows: Row[] = (Array.isArray(body.rows) ? body.rows : []).slice(0, 4).map((row: any) => ({
      line: String(row?.line ?? "").slice(0, 64),
      stop: String(row?.stop ?? "").slice(0, 200),
      direction: String(row?.direction ?? "").slice(0, 64),
      shown: (Array.isArray(row?.shown) ? row.shown : []).map(Number).filter(Number.isFinite).slice(0, 3),
    })).filter((row: Row) => row.line && row.stop);
    const until = Number(body.until);
    if (!CITIES.includes(body.city) || rows.length === 0 || !Number.isFinite(until) || until < now || until > now + 24 * 60 * 60) {
      return reply({ error: "city, rows and until are required" }, 400);
    }
    const existing = await this.ctx.storage.get<Widgets>(`w:${token}`);
    if (!existing && (await this.ctx.storage.list({ prefix: "w:", limit: MOST_PER_SHARD })).size >= MOST_PER_SHARD) {
      return reply({ error: "too many widgets" }, 503);
    }
    const widgets: Widgets = {
      token,
      environment: body.environment === "production" ? "production" : "sandbox",
      city: body.city,
      rows,
      reportedAt: now,
      until,
      pushedAt: existing?.pushedAt,
      day: existing?.day,
      pushes: existing?.pushes,
    };
    await this.ctx.storage.put(`w:${token}`, widgets);
    if (await this.ctx.storage.getAlarm() === null) await this.ctx.storage.setAlarm(Date.now() + CHECK_EVERY_MS);
    return reply({ ok: true });
  }

  async alarm(): Promise<void> {
    const all = [...(await this.ctx.storage.list<Widgets>({ prefix: "w:" })).values()];
    const now = Date.now() / 1000;
    const today = new Date().toISOString().slice(0, 10);
    const lookups = new Map<string, Promise<number[] | undefined>>();
    const lookUp = (city: string, row: Row) => {
      const key = `${city}|${row.line}|${row.stop}|${row.direction}`;
      if (!lookups.has(key)) lookups.set(key, departures(city, row, this.env));
      return lookups.get(key)!;
    };
    await Promise.all(all.map(async (widgets) => {
      if (now - widgets.reportedAt > FORGOTTEN_AFTER_SECONDS) return this.ctx.storage.delete(`w:${widgets.token}`);
      const pushes = widgets.day === today ? widgets.pushes ?? 0 : 0;
      // Just fetched (or just pushed), or pushed enough today: nothing to do yet.
      if (pushes >= MOST_A_DAY || now - widgets.reportedAt < 60 || now - (widgets.pushedAt ?? 0) < LEAST_APART_SECONDS) return;
      const why = widgets.until - now < CHECK_EVERY_MS / 1000 ? "running out" : await this.offBy(widgets, lookUp, now);
      if (!why) return;
      const status = await this.apns.send({
        token: widgets.token, environment: widgets.environment, topic: TOPIC, type: "widgets",
        aps: { "content-changed": true },
      });
      if (status === "gone") await this.ctx.storage.delete(`w:${widgets.token}`);
      else if (status === "ok") await this.ctx.storage.put(`w:${widgets.token}`, { ...widgets, pushedAt: now, day: today, pushes: pushes + 1 });
      else if (!this.apns.configured) console.log(`widget push for ${widgets.token.slice(0, 8)}… (${why}): no APNs key`);
    }));
    const left = (await this.ctx.storage.list({ prefix: "w:", limit: 1 })).size;
    if (left > 0) await this.ctx.storage.setAlarm(Date.now() + CHECK_EVERY_MS);
  }

  /** Why `widgets` show the wrong next departure for one of their rows, if they do. */
  private async offBy(widgets: Widgets, lookUp: (city: string, row: Row) => Promise<number[] | undefined>, now: number): Promise<string | undefined> {
    for (const row of widgets.rows) {
      const actual = await lookUp(widgets.city, row);
      // Not known now: no reason to think the widget is wrong.
      if (!actual) continue;
      const next = actual.find((time) => time > now - 30);
      const shown = row.shown.find((time) => time > now - 30);
      if ((next === undefined) !== (shown === undefined)) return `${row.line}: ${shown === undefined ? "a bus" : "no bus"} now`;
      if (next !== undefined && shown !== undefined && Math.abs(next - shown) >= OFF_BY_SECONDS) {
        return `${row.line}: ${Math.round((next - shown) / 60)} min off`;
      }
    }
    return undefined;
  }
}

/** A stop's departures (seconds since 1970), through the proxy's own routes (and caches). */
async function departures(city: string, row: Row, env: WidgetEnv): Promise<number[] | undefined> {
  const base = `https://bus37-proxy.internal/v1/${city === "sf" ? "" : city + "/"}`;
  const query = new URLSearchParams({ stop: row.stop, line: row.line, direction: row.direction });
  try {
    const response = await proxy.fetch(new Request(`${base}departures?${query}`, { headers: { "X-Client": "widgetpush" } }), env as any);
    if (!response.ok) return undefined;
    const data = (await response.json()) as any;
    return (data.departures ?? []).map((d: any) => Date.parse(d.time) / 1000).filter(Number.isFinite);
  } catch {
    return undefined;
  }
}

function reply(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
}
