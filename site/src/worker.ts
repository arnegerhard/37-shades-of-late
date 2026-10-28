// The site is static files, except for /s, a shared stop: its link preview (what Messages, WhatsApp
// and friends show for the link) names the line and stop rather than any old bus, looked up from the
// proxy like the page itself does, with /s/card.png, the stop's card with its current wait, as the
// picture.

import { renderCard } from "./card";

interface Env {
  ASSETS: { fetch(request: Request): Promise<Response> };
}

const API = "https://bus37-proxy.arne-5c1.workers.dev/v1/";

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/s/card.png") return card(request, url, ctx);
    const page = await env.ASSETS.fetch(request);
    if (url.pathname !== "/s" || !page.ok) return page;
    const ride = await lookUp(url.searchParams).catch(() => undefined);
    if (!ride) return page;
    const title = `The ${ride.line} at ${ride.stop}`;
    const description = `Live minutes until the ${ride.line} to ${ride.destination} shows up, and how to feel about it.`;
    // Always https: previews won't fetch a picture over plain http.
    const image = `https://${url.host}/s/card.png${url.search}`;
    const set = (content: string) => ({ element: (tag: Element) => { tag.setAttribute("content", content); } });
    return new HTMLRewriter()
      .on('meta[property="og:title"]', set(title))
      .on('meta[property="og:description"]', set(description))
      .on('meta[name="description"]', set(description))
      .on('meta[property="og:image"]', set(image))
      .on('meta[name="twitter:image"]', set(image))
      .on("title", { element: (tag) => { tag.setInnerContent(`${title} · 37 Shades of Late`); } })
      .transform(page);
  },
};

/** The stop's card, with its wait as of now; kept for a minute, as previews are fetched in bursts. */
async function card(request: Request, url: URL, ctx: ExecutionContext): Promise<Response> {
  const cache = (caches as unknown as { default: Cache }).default;
  const cached = await cache.match(request);
  if (cached) return cached;
  const ride = await lookUp(url.searchParams).catch(() => undefined);
  if (!ride) return new Response("not found", { status: 404 });
  const upcoming = (await departures(url.searchParams).catch(() => []))
    .filter((d) => Date.parse(d.time) > Date.now() - 30_000).slice(0, 3);
  const minutes = upcoming.map((d) => Math.max(0, Math.floor((Date.parse(d.time) - Date.now()) / 60_000)));
  const png = await renderCard({
    badge: ride.badge,
    destination: ride.destination,
    stop: ride.stop,
    minutes,
    live: upcoming[0]?.live ?? false,
    lines: ride.combined ? upcoming.map((d) => d.line ?? "") : undefined,
    quip: minutes.length ? quip(minutes[0], upcoming[0].line || ride.first) : `Schrödinger's ${ride.line}: both coming and not coming.`,
  });
  const response = new Response(png, { headers: { "Content-Type": "image/png", "Cache-Control": "public, max-age=60" } });
  ctx.waitUntil(cache.put(request, response.clone()));
  return response;
}

/** As the page's own quips (pages/s.html). */
function quip(minutes: number, line: string): string {
  if (minutes < 4) return `Holy shit, the ${line} is real.`;
  if (minutes < 9) return "Stay put, lazy bastard.";
  if (minutes < 16) return "Make coffee. Reconsider your life.";
  return "Walking is starting to look attractive.";
}

/** The base URL of the proxy for the link's city, or nothing for one it doesn't know. */
function base(params: URLSearchParams): string | undefined {
  const city = params.get("c") ?? "sf";
  return /^(sf|seattle|nyc)$/.test(city) ? API + (city === "sf" ? "" : city + "/") : undefined;
}

/** The line, stop and destination a shared link points to: /s?c=sf&l=37&s=13254&d=IB. Combined lines
 * come as lists (l=K,L,M&d=IB,IB,IB); the stop and destination are the first one's, and `line` names them all. */
async function lookUp(params: URLSearchParams) {
  const ids = (params.get("l") ?? "").split(",").filter(Boolean);
  const [line, stop, way] = [ids[0], params.get("s")?.split(",")[0], params.get("d")?.split(",")[0]];
  const api = base(params);
  if (!line || !stop || !api) return undefined;
  const response = await fetch(`${api}lines/${encodeURIComponent(line)}?client=web`, { cf: { cacheTtl: 3600 } });
  if (!response.ok) return undefined;
  const data: { directions?: { id: string; destination: string; stops: { code: string; name: string }[] }[] } = await response.json();
  const directions = data.directions ?? [];
  const direction = directions.find((d) => d.id === way && d.stops.some((s) => s.code === stop))
    ?? directions.find((d) => d.stops.some((s) => s.code === stop));
  const name = direction?.stops.find((s) => s.code === stop)?.name;
  const spoken = ids.length > 1 ? ids.slice(0, -1).join(", ") + " or " + ids[ids.length - 1] : line;
  // As the app's badges: "37", "KLM", "5·21".
  const badge = ids.join(ids.every((id) => id.length === 1) ? "" : "·");
  return direction && name
    ? { line: spoken, first: line, badge, combined: ids.length > 1, stop: name, destination: direction.destination }
    : undefined;
}

/** The link's departures, all its lines merged, as the page asks for them. */
async function departures(params: URLSearchParams): Promise<{ time: string; live: boolean; line?: string }[]> {
  const api = base(params);
  if (!api) return [];
  const query = new URLSearchParams({ stop: params.get("s") ?? "", line: params.get("l") ?? "", direction: params.get("d") ?? "", client: "web" });
  const response = await fetch(`${api}departures?${query}`);
  return response.ok ? ((await response.json()) as any).departures ?? [] : [];
}
