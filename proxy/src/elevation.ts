/**
 * Heights above sea level, for walking times that know a hill from a flat street (the app's trips):
 *
 *   GET /v1/elevation?points=37.7676,-122.4410|37.7697,-122.4294   meters for each, in order (up to 100)
 *
 * From Open-Meteo's elevation API (90 m terrain data, no key). Points are rounded to about 10 m before
 * they go there, and each one's height is kept a month in the Worker's cache (a stop's is the same
 * every time), so most answers never leave Cloudflare.
 */

const API = "https://api.open-meteo.com/v1/elevation";
const KEEP_SECONDS = 30 * 86_400;
const MOST = 100;

export async function handleElevation(url: URL): Promise<Response> {
  const points = (url.searchParams.get("points") ?? "").split("|").filter(Boolean).slice(0, MOST)
    .map((p) => p.split(",").map(Number))
    .filter(([lat, lon]) => Number.isFinite(lat) && Number.isFinite(lon) && Math.abs(lat) <= 90 && Math.abs(lon) <= 180);
  if (!points.length) return reply({ error: "points (lat,lon|lat,lon…) are required" }, 400);
  try {
    return reply({ elevations: await elevations(points) }, 200);
  } catch (error) {
    return reply({ error: (error as Error).message }, 502);
  }
}

/** Meters above sea level for each point (any number of them, a hundred to a call), in order; null where
 *  unknown. Rounded to about 11 m first: close enough for a hill, not an address. */
export async function elevations(raw: number[][]): Promise<(number | null)[]> {
  const points = raw.map(([lat, lon]) => [Math.round(lat * 1e4) / 1e4, Math.round(lon * 1e4) / 1e4]);
  const cache = caches.default;
  const key = ([lat, lon]: number[]) => new Request(`https://elevation.cache/${lat},${lon}`);
  const heights: (number | null)[] = await Promise.all(points.map(async (p) => {
    const hit = await cache.match(key(p));
    return hit ? Number(await hit.text()) : null;
  }));
  const missing = points.map((p, i) => (heights[i] === null ? i : -1)).filter((i) => i >= 0);
  for (let start = 0; start < missing.length; start += MOST) {
    const batch = missing.slice(start, start + MOST);
    const query = new URLSearchParams({
      latitude: batch.map((i) => points[i][0]).join(","),
      longitude: batch.map((i) => points[i][1]).join(","),
    });
    // Open-Meteo turns away bursts: a moment's pause, a few times, before giving up.
    let response = await fetch(`${API}?${query}`);
    for (let tries = 0; response.status === 429 && tries < 6; tries++) {
      await new Promise((resolve) => setTimeout(resolve, 1_500 * (tries + 1)));
      response = await fetch(`${API}?${query}`);
    }
    if (!response.ok) throw new Error(`elevation ${response.status}`);
    const found = ((await response.json()) as { elevation?: number[] }).elevation ?? [];
    await Promise.all(batch.map(async (i, n) => {
      const height = found[n];
      if (!Number.isFinite(height)) return;
      heights[i] = height;
      await cache.put(key(points[i]), new Response(String(height), { headers: { "Cache-Control": `max-age=${KEEP_SECONDS}` } }));
    }));
  }
  return heights;
}

function reply(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
}
