# 37 Shades of Late

**37 Shades of Late** is an iOS app with Home Screen and Lock Screen widgets showing the next Muni departures for a line
and stop you pick in the app. Defaults to the inbound 37 Corbett toward the Haight at
14th St & Church St (stop 13254), one block from Market & Church.

## How it fits together

- **App** (`App/`): pick a line, direction and stop. The choice is saved to the
  `group.info.jetsons.bus37` App Group so the widgets use it too.
- **Favorites**: save the current line and stop with Save; tap one to show it in the app and on
  the widgets; swipe to delete, Edit to reorder. Stored in the same App Group.
- **Map** (`App/RouteMap.swift`): the route in the chosen direction (stops joined in order),
  the chosen stop, and live buses headed to it, refreshed every 30 seconds.
- **Widget** (`Widget/`): small/medium Home Screen and rectangular/circular/inline Lock Screen.
- **Proxy** (`proxy/`): Cloudflare Worker at https://bus37-proxy.arne-5c1.workers.dev that
  holds the 511.org API key so all installs share one key. A single Durable Object fetches
  every Muni stop's predictions in **one** 511 call (~10 MB) and answers all stops and users
  from that shared snapshot, refreshing it every 70s (`SNAPSHOT_TTL_SECONDS`) via an alarm
  while anyone asked in the last 5 minutes, and not at all when nobody is using the app.
  That's ~51 calls/hour against 511's 60/hour per key, whatever the number of stops; a
  rolling hourly budget guards the limit, and when it runs out the last snapshot is served.

  | Endpoint | Returns |
  | --- | --- |
  | `GET /v1/lines` | all Muni lines (cached 24h) |
  | `GET /v1/lines/:line` | directions and their stops in order, with coordinates (cached 24h) |
  | `GET /v1/departures?stop=&line=&direction=` | upcoming departures and live bus positions, plus `fetchedAt`/`nextRefreshAt` of the shared snapshot |

## Usage statistics

Each request carries a random install ID the app generates (`AppGroup.installID`), the part of
the app that made it (`X-Client`: app, widget or map), the favorites count and app version.
The proxy writes one anonymous event per request to the Workers Analytics Engine dataset
`37ShadesOfLate` (columns documented at `recordUsage` in `proxy/src/index.ts`); no IPs or
locations. Query it with the Analytics Engine SQL API (the name starts with a digit, so quote
it), e.g. installs per day:

    SELECT toStartOfDay(timestamp) AS day, count(DISTINCT blob6) AS installs
    FROM "37ShadesOfLate" WHERE timestamp > NOW() - INTERVAL '7' DAY GROUP BY day ORDER BY day

For a quick report (installs per day, app vs. widget vs. map, active days per install, top
lines and stops, busy hours, favorites), save a Cloudflare API token with Account Analytics: Read
to `proxy/.analytics-token` (git-ignored) and run `proxy/stats.sh [days]`.

## Working on it

- Open `Bus37.xcodeproj` in Xcode and run. Edit the project in Xcode directly.
- Proxy: `cd proxy && npm install`, then `npx wrangler deploy`. The key is the
  `API_KEY_511` secret (`npx wrangler secret put API_KEY_511`). Tune `HOURLY_BUDGET` and the
  TTLs in `wrangler.jsonc`; if 511 raises your limit, raise `HOURLY_BUDGET` to match.

## App Store

- Listing text, URLs and review notes: `AppStore/listing.md`.
- Screenshots: `AppStore/screenshots/` (iPhone 6.9" and iPad 13"). Regenerate with
  `AppStore/capture.sh <simulator-udid> <output-prefix>` after installing a Debug build; it
  launches the app with `-screen home|lines|stops|widgets|lock` (debug-only, see
  `App/Screenshots.swift`).
- Privacy policy and support pages are served by the proxy at `/privacy` and `/support`.
  Set a `SUPPORT_EMAIL` var in `proxy/wrangler.jsonc` to show a contact address.
