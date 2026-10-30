import { DurableObject } from "cloudflare:workers";
import proxy from "./index";

/**
 * Live Activities: a stop's next departure on someone's Dynamic Island and Lock Screen (see
 * Shared/BusActivity.swift in the app), kept current with push updates while they're in another app.
 *
 *   POST /v1/activity      {token, environment, city, line, stop, direction, startedAt}: start (or keep)
 *                          pushing to an activity's push token. `environment` is "sandbox" for builds
 *                          from Xcode, "production" otherwise; `startedAt` is in seconds since 1970
 *   POST /v1/activity/end  {token}: the app ended it, stop pushing
 *
 * They're spread over SHARDS Durable Objects by push token, as each alarm can only make so many
 * requests (about a thousand: a few per stop, and a push per activity), so one object would stop
 * keeping up at a few hundred people watching at once. While any of an object's are running, its alarm looks at their departures every
 * 30 seconds (through the proxy's own routes, so it shares their caches), pushes when the next or the
 * following departure moved, or the bus passed a stop (and every two minutes regardless, so the
 * activity's "updated … ago" stays true), and ends each one once it's over: when the departure after the watched
 * one is due, or an hour after it started, whichever comes first (as the app works it out). An
 * activity's token, stop and times are kept only until then.
 */

export interface ActivityEnv {
  ACTIVITIES: DurableObjectNamespace<LiveActivities>;
  /** The APNs auth key (.p8, PEM) and its id, for signing push requests. */
  APNS_KEY?: string;
  APNS_KEY_ID?: string;
}

const TEAM_ID = "DLJLEZ2Y6W";
const TOPIC = "info.jetsons.bus37.push-type.liveactivity";
const LONGEST_SECONDS = 60 * 60;
const CHECK_EVERY_MS = 30_000;
/** Pushed at least this often, for the "updated … ago". */
const REFRESH_EVERY_SECONDS = 120;
/** How many Durable Objects share the activities, and how many each takes (leaving room in its
 * alarm's requests for the departures it looks up): about 9,600 watching at once. */
const SHARDS = 32;
const MOST_PER_SHARD = 300;
/** Seconds from 1970 to 2001, where Swift's Codable dates count from. */
const SWIFT_EPOCH = 978_307_200;

interface Watch {
  token: string;
  environment: "sandbox" | "production";
  city: "sf" | "seattle" | "nyc" | "boston";
  line: string;
  stop: string;
  direction: string;
  /** Seconds since 1970. */
  startedAt: number;
  /** The last state pushed, to push only what changed, and when (seconds since 1970). */
  sent?: State;
  sentAt?: number;
}

/** As BusActivity.ContentState, with dates as seconds since 1970. */
interface State {
  next: number;
  nextIsLive: boolean;
  after?: number;
  ends: number;
  updatedAt?: number;
  stopsAway?: number;
}

/** Hands an activity request to its token's Durable Object; nothing else about it touches the rest of the proxy. */
export async function handleActivity(request: Request, env: ActivityEnv, path: string): Promise<Response> {
  const body = await request.text();
  let token = "";
  try { token = String(JSON.parse(body)?.token ?? ""); } catch { /* the object turns it away */ }
  // The same token always lands on the same object, so its updates and its end meet up there.
  // ("activities-v1", from before there were shards, ends its last activities on its own.)
  const stub = env.ACTIVITIES.get(env.ACTIVITIES.idFromName(`activities-v2-${shard(token)}`));
  return stub.fetch(new Request(`https://activities${path}`, { method: "POST", body }));
}

/** Which of the SHARDS objects `token` belongs to (FNV-1a). */
function shard(token: string): number {
  let hash = 0x811c9dc5;
  for (let i = 0; i < token.length; i++) hash = Math.imul(hash ^ token.charCodeAt(i), 0x01000193);
  return (hash >>> 0) % SHARDS;
}

export class LiveActivities extends DurableObject<ActivityEnv> {
  private jwt?: { token: string; madeAt: number };

  async fetch(request: Request): Promise<Response> {
    const { pathname } = new URL(request.url);
    let body: any;
    try { body = await request.json(); } catch { return reply({ error: "JSON body required" }, 400); }
    const token = String(body?.token ?? "");
    if (!/^[0-9a-f]{16,400}$/.test(token)) return reply({ error: "token (hex) is required" }, 400);

    if (pathname === "/v1/activity/end") {
      await this.ctx.storage.delete(`a:${token}`);
      return reply({ ok: true });
    }

    const watch: Watch = {
      token,
      environment: body.environment === "production" ? "production" : "sandbox",
      city: body.city,
      line: String(body.line ?? "").slice(0, 64),
      stop: String(body.stop ?? "").slice(0, 200),
      direction: String(body.direction ?? "").slice(0, 64),
      startedAt: Number(body.startedAt),
    };
    const now = Date.now() / 1000;
    if (!["sf", "seattle", "nyc", "boston"].includes(watch.city) || !watch.line || !watch.stop
        || !Number.isFinite(watch.startedAt) || watch.startedAt < now - LONGEST_SECONDS || watch.startedAt > now + 60) {
      return reply({ error: "city, line, stop and a recent startedAt are required" }, 400);
    }
    const existing = await this.ctx.storage.get<Watch>(`a:${token}`);
    if (!existing && (await this.ctx.storage.list({ prefix: "a:", limit: MOST_PER_SHARD })).size >= MOST_PER_SHARD) {
      return reply({ error: "too many activities" }, 503);
    }
    await this.ctx.storage.put(`a:${token}`, { ...watch, sent: existing?.sent });
    if (await this.ctx.storage.getAlarm() === null) await this.ctx.storage.setAlarm(Date.now() + CHECK_EVERY_MS);
    return reply({ ok: true });
  }

  async alarm(): Promise<void> {
    const watches = [...(await this.ctx.storage.list<Watch>({ prefix: "a:" })).values()];
    if (watches.length === 0) return;
    // A stop and line watched by several people is looked up once.
    const lookups = new Map<string, Promise<Lookup | undefined>>();
    await Promise.all(watches.map(async (watch) => {
      const key = `${watch.city}|${watch.line}|${watch.stop}|${watch.direction}`;
      if (!lookups.has(key)) lookups.set(key, departures(watch, this.env));
      const state = stateFor(await lookups.get(key), watch);
      const now = Date.now() / 1000;
      if (!state || state.ends <= now || watch.startedAt + LONGEST_SECONDS <= now) {
        await this.push(watch, "end", state ?? watch.sent);
        await this.ctx.storage.delete(`a:${watch.token}`);
      } else if (!watch.sent || moved(watch.sent, state) || now - (watch.sentAt ?? 0) >= REFRESH_EVERY_SECONDS) {
        const status = await this.push(watch, "update", state);
        // A failed push is tried again next time.
        if (status === "gone") await this.ctx.storage.delete(`a:${watch.token}`);
        else if (status === "ok") await this.ctx.storage.put(`a:${watch.token}`, { ...watch, sent: state, sentAt: now });
      }
    }));
    const left = (await this.ctx.storage.list({ prefix: "a:", limit: 1 })).size;
    if (left > 0) await this.ctx.storage.setAlarm(Date.now() + CHECK_EVERY_MS);
  }

  /** Sends one push; "gone" when the token is no good any more (the activity ended on the phone). */
  private async push(watch: Watch, event: "update" | "end", state?: State): Promise<"ok" | "gone" | "failed"> {
    const jwt = await this.signedToken();
    if (!jwt) return "failed";
    const now = Math.floor(Date.now() / 1000);
    const aps: Record<string, unknown> = { timestamp: now, event };
    if (state) {
      aps["content-state"] = {
        next: state.next - SWIFT_EPOCH,
        nextIsLive: state.nextIsLive,
        ...(state.after ? { after: state.after - SWIFT_EPOCH } : {}),
        ends: state.ends - SWIFT_EPOCH,
        ...(state.updatedAt ? { updatedAt: state.updatedAt - SWIFT_EPOCH } : {}),
        ...(state.stopsAway !== undefined ? { stopsAway: state.stopsAway } : {}),
      };
      aps["stale-date"] = Math.ceil(state.ends);
    }
    if (event === "end") aps["dismissal-date"] = now;
    const host = watch.environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
    try {
      const response = await fetch(`https://${host}/3/device/${watch.token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": TOPIC,
          "apns-push-type": "liveactivity",
          "apns-priority": "10",
          "content-type": "application/json",
        },
        body: JSON.stringify({ aps }),
      });
      if (response.ok) return "ok";
      const reason = String(((await response.json().catch(() => ({}))) as any).reason ?? "");
      if (["BadDeviceToken", "Unregistered", "ExpiredToken", "DeviceTokenNotForTopic"].includes(reason)) return "gone";
      if (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken") this.jwt = undefined;
      return "failed";
    } catch {
      return "failed";
    }
  }

  /** The ES256 token APNs wants, made again every 40 minutes (it takes them for up to an hour). */
  private async signedToken(): Promise<string | undefined> {
    const now = Math.floor(Date.now() / 1000);
    if (this.jwt && now - this.jwt.madeAt < 40 * 60) return this.jwt.token;
    const pem = this.env.APNS_KEY, keyID = this.env.APNS_KEY_ID;
    if (!pem || !keyID) return undefined;
    const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")), (c) => c.charCodeAt(0));
    const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
    const encode = (value: object) => base64url(new TextEncoder().encode(JSON.stringify(value)));
    const unsigned = `${encode({ alg: "ES256", kid: keyID.trim() })}.${encode({ iss: TEAM_ID, iat: now })}`;
    // WebCrypto's ECDSA signature is r and s back to back, as JWTs want them.
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(unsigned));
    this.jwt = { token: `${unsigned}.${base64url(new Uint8Array(signature))}`, madeAt: now };
    return this.jwt.token;
  }
}

interface Departure {
  time: string;
  live: boolean;
  vehicle?: { lat: number; lon: number };
}

interface Lookup {
  departures: Departure[];
  fetchedAt?: number;
  /** The stops of the watched line's direction, for how far the bus is. */
  route?: { code: string; lat?: number; lon?: number }[];
}

/** The watched stop's departures, and its line's stops, through the proxy's own routes (and caches). */
async function departures(watch: Watch, env: ActivityEnv): Promise<Lookup | undefined> {
  const base = `https://bus37-proxy.internal/v1/${watch.city === "sf" ? "" : watch.city + "/"}`;
  const get = async (path: string) => {
    const response = await proxy.fetch(new Request(base + path, { headers: { "X-Client": "activity" } }), env as any);
    return response.ok ? ((await response.json()) as any) : undefined;
  };
  try {
    const query = new URLSearchParams({ stop: watch.stop, line: watch.line, direction: watch.direction });
    // With several lines, the first one's (the bus being watched is usually on it).
    const [line, direction, stop] = [watch.line, watch.direction, watch.stop].map((list) => list.split(",")[0]);
    const [data, lineData] = await Promise.all([get(`departures?${query}`), get(`lines/${encodeURIComponent(line)}`).catch(() => undefined)]);
    if (!data) return undefined;
    const route = lineData?.directions?.find((d: any) => d.id === direction && d.stops?.some((s: any) => s.code === stop))?.stops;
    return { departures: data.departures ?? [], fetchedAt: Date.parse(data.fetchedAt) / 1000 || undefined, route };
  } catch {
    return undefined;
  }
}

/** As BusActivity.ContentState(departures:since:…) in the app. */
function stateFor(lookup: Lookup | undefined, watch: Watch): State | undefined {
  const now = Date.now() / 1000;
  const upcoming = (lookup?.departures ?? []).filter((d) => Date.parse(d.time) / 1000 > now - 30);
  const next = upcoming[0];
  if (!next) return undefined;
  const nextTime = Date.parse(next.time) / 1000;
  const after = upcoming[1] ? Date.parse(upcoming[1].time) / 1000 : undefined;
  const stop = watch.stop.split(",")[0];
  return {
    next: nextTime,
    nextIsLive: next.live,
    after,
    ends: Math.min(watch.startedAt + LONGEST_SECONDS, after ?? nextTime + 60),
    updatedAt: lookup?.fetchedAt,
    stopsAway: next.vehicle && lookup?.route ? stopsAway(next.vehicle, stop, lookup.route) : undefined,
  };
}

/** Stops from the one `vehicle` is nearest (before `stop`, within 400 m) to `stop`. As in BusActivity.swift. */
function stopsAway(vehicle: { lat: number; lon: number }, stop: string, route: { code: string; lat?: number; lon?: number }[]): number | undefined {
  const here = route.findIndex((s) => s.code === stop);
  if (here < 0) return undefined;
  const meters = (s: { lat?: number; lon?: number }) => s.lat === undefined || s.lon === undefined ? Infinity
    : Math.hypot((s.lon - vehicle.lon) * 111_320 * Math.cos((vehicle.lat * Math.PI) / 180), (s.lat - vehicle.lat) * 110_540);
  let nearest = 0;
  for (let i = 1; i <= here; i++) if (meters(route[i]) < meters(route[nearest])) nearest = i;
  return meters(route[nearest]) < 400 ? here - nearest : undefined;
}

/** Worth a push: a departure moved by half a minute or more, turned live, or the bus passed a stop. */
function moved(a: State, b: State): boolean {
  const apart = (x?: number, y?: number) => (x === undefined) !== (y === undefined) || Math.abs((x ?? 0) - (y ?? 0)) >= 30;
  return apart(a.next, b.next) || apart(a.after, b.after) || a.nextIsLive !== b.nextIsLive || a.stopsAway !== b.stopsAway;
}

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function reply(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
}
