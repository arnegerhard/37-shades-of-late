// Apple Maps for the shared-stop page: tokens for MapKit JS (the page's live map) and signed Web
// Snapshots (the still of it in the link preview's card), both signed with the MapKit JS key
// (secrets MAPKIT_KEY, the .p8, and MAPKIT_KEY_ID).

export interface MapKitEnv {
  MAPKIT_KEY?: string;
  MAPKIT_KEY_ID?: string;
}

const TEAM_ID = "DLJLEZ2Y6W";

let signingKey: Promise<CryptoKey> | undefined;

function key(env: MapKitEnv): Promise<CryptoKey> | undefined {
  if (!env.MAPKIT_KEY) return undefined;
  const der = Uint8Array.from(atob(env.MAPKIT_KEY.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")), (c) => c.charCodeAt(0));
  signingKey ??= crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  return signingKey;
}

/** ES256, as r and s back to back, which is what both JWTs and snapshot signatures want. */
async function sign(env: MapKitEnv, text: string): Promise<string | undefined> {
  const signer = key(env);
  if (!signer) return undefined;
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, await signer, new TextEncoder().encode(text));
  return base64url(new Uint8Array(signature));
}

/** A MapKit JS token for pages on `origin`, good for half an hour. */
export async function mapkitToken(env: MapKitEnv, origin: string): Promise<string | undefined> {
  if (!env.MAPKIT_KEY_ID) return undefined;
  const now = Math.floor(Date.now() / 1000);
  const encode = (value: object) => base64url(new TextEncoder().encode(JSON.stringify(value)));
  const unsigned = `${encode({ alg: "ES256", kid: env.MAPKIT_KEY_ID.trim(), typ: "JWT" })}.${encode({ iss: TEAM_ID, iat: now, exp: now + 1800, origin })}`;
  const signature = await sign(env, unsigned);
  return signature && `${unsigned}.${signature}`;
}

export interface Point { lat: number; lon: number }

/** A dark, muted map of `size` (points) around `center` at zoom `z`, as PNG bytes. */
export async function snapshot(env: MapKitEnv, center: Point, z: number, size: { width: number; height: number }): Promise<Uint8Array | undefined> {
  if (!env.MAPKIT_KEY_ID) return undefined;
  const query = new URLSearchParams({
    center: `${center.lat.toFixed(6)},${center.lon.toFixed(6)}`,
    z: String(z),
    size: `${size.width}x${size.height}`,
    scale: "1",
    t: "mutedStandard",
    colorScheme: "dark",
    poi: "0",
    teamId: TEAM_ID,
    keyId: env.MAPKIT_KEY_ID.trim(),
  });
  const path = `/api/v1/snapshot?${query}`;
  const signature = await sign(env, path);
  if (!signature) return undefined;
  const response = await fetch(`https://snapshot.apple-mapkit.com${path}&signature=${signature}`, { cf: { cacheTtl: 86_400 } });
  return response.ok ? new Uint8Array(await response.arrayBuffer()) : undefined;
}

/** Web Mercator, in points at zoom `z` (a 256-point world at zoom 0), as Apple's snapshots use it. */
export function project(point: Point, z: number): { x: number; y: number } {
  const world = 256 * 2 ** z;
  const sin = Math.sin((point.lat * Math.PI) / 180);
  return { x: ((point.lon + 180) / 360) * world, y: (0.5 - Math.log((1 + sin) / (1 - sin)) / (4 * Math.PI)) * world };
}

export function unproject(x: number, y: number, z: number): Point {
  const world = 256 * 2 ** z;
  const n = Math.PI - (2 * Math.PI * y) / world;
  return { lat: (180 / Math.PI) * Math.atan(Math.sinh(n)), lon: (x / world) * 360 - 180 };
}

function base64url(bytes: Uint8Array): string {
  let text = "";
  for (const byte of bytes) text += String.fromCharCode(byte);
  return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
