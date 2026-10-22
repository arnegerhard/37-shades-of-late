# 37 Shades of Late

**37 Shades of Late** is an iOS app with Home Screen and Lock Screen widgets showing the next departures for a line
and stop you pick in the app, in San Francisco (Muni) or Seattle (King County Metro, Sound Transit, Seattle
Streetcar). A new install starts in the nearer city: the inbound 37 Corbett at 14th St & Church St (stop 13254)
in SF, or the 8 toward Mount Baker at Denny Way & Fairview Ave (stop 1_2260) in Seattle.

## How it fits together

- **App** (`App/`): pick a city, line, direction and stop. The choice (including its `City`) is saved
  to the `group.info.jetsons.bus37` App Group so the widgets use it too. On first launch the app asks
  the proxy's `/v1/city` for the nearer supported city; there's no location permission.
- **Favorites**: save the current line and stop with Save; tap one to show it in the app and on
  the widgets; swipe to delete, Edit to reorder. Stored in the same App Group.
- **Map** (`App/RouteMap.swift`): the route in the chosen direction (Seattle's real street shapes;
  in SF the stops joined in order), the chosen stop, and live buses on the route headed to it,
  refreshed whenever the proxy has newer data.
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
  | `GET /v1/city` | `sf` or `seattle`, whichever is nearer Cloudflare's rough IP location of the caller (not stored) |

  **Seattle** (`proxy/src/seattle.ts`) uses OneBusAway Puget Sound under `/v1/seattle/lines`,
  `/v1/seattle/lines/:line` (adds `shapes`, the real route polylines) and `/v1/seattle/departures`.
  OneBusAway has no all-stops call, so departures are cached per stop for 60s. Line ids are rider-facing
  codes ("8", "E Line", "SLU"); the proxy maps them to OneBusAway route ids. A bus only counts as live,
  and shows on the map, once it's running that trip (`activeTripId`). The key is the `OBA_API_KEY`
  secret (`npx wrangler secret put OBA_API_KEY`); until it's set the public, heavily rate-limited
  `TEST` key is used.

## Website

`site/` is the marketing page for 37shadesoflate.com: `index.src.html` plus the two screenshots in
`site/images/`, plus the privacy and support pages in `site/pages/`. `site/build.sh` inlines the screenshots into one self-contained `site/public/index.html` (git-ignored),
which a static-assets Cloudflare Worker (`site/wrangler.jsonc`) serves. It shows the live next 37 at
Church & 14th via the proxy (requests tagged `client=web`). Deploy with `site/build.sh` then
`npx --prefix proxy wrangler deploy` from `site/`.

## Usage statistics

Each request carries a random install ID the app generates (`AppGroup.installID`), the part of
the app that made it (`X-Client`: app, widget or map), the favorites count and app version. The city
(blob8: sf or seattle) comes from the request path.
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
- Privacy policy and support pages: https://37shadesoflate.com/privacy and `/support`, from
  `site/pages/`. The proxy's old `/privacy` and `/support` addresses redirect there.
