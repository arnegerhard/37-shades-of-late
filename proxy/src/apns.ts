/**
 * Sending pushes through APNs, for the Live Activities (activities.ts) and the widgets (widgets.ts).
 * One `APNs` per Durable Object keeps its signed token, made again every 40 minutes.
 */

export interface APNsEnv {
  /** The APNs auth key (.p8, PEM) and its id, for signing push requests. */
  APNS_KEY?: string;
  APNS_KEY_ID?: string;
}

const TEAM_ID = "DLJLEZ2Y6W";

export interface Push {
  token: string;
  /** "sandbox" for builds from Xcode, "production" otherwise. */
  environment: "sandbox" | "production";
  topic: string;
  type: "liveactivity" | "widgets";
  aps: Record<string, unknown>;
  priority?: 5 | 10;
}

export class APNs {
  private jwt?: { token: string; madeAt: number };

  constructor(private env: APNsEnv) {}

  /** Sends one push; "gone" when the token is no good any more (the activity ended, the widget's gone). */
  async send(push: Push): Promise<"ok" | "gone" | "failed"> {
    const jwt = await this.signedToken();
    if (!jwt) return "failed";
    const host = push.environment === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
    try {
      const response = await fetch(`https://${host}/3/device/${push.token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": push.topic,
          "apns-push-type": push.type,
          "apns-priority": String(push.priority ?? 10),
          "content-type": "application/json",
        },
        body: JSON.stringify({ aps: push.aps }),
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

  /** Whether there's a key to sign with at all (there isn't in `wrangler dev`). */
  get configured(): boolean {
    return Boolean(this.env.APNS_KEY && this.env.APNS_KEY_ID);
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

/** Which of `shards` Durable Objects `token` belongs to (FNV-1a), so a token always lands on the same one. */
export function shard(token: string, shards: number): number {
  let hash = 0x811c9dc5;
  for (let i = 0; i < token.length; i++) hash = Math.imul(hash ^ token.charCodeAt(i), 0x01000193);
  return (hash >>> 0) % shards;
}

function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
