# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

The product is the native SwiftUI iPhone app (`App/`) and its widgets (`Widget/`, views in `Shared/`). The website in `site/` (37shadesoflate.com: marketing page, privacy, support, and an internal stats page) supports the app and is a web surface.

## Users

Daily regulars: people who ride the same few lines every day in San Francisco, Seattle, New York, Boston or Los Angeles. They want to know when to leave for their stop without opening a trip planner, and they get that at a glance on the Home Screen, Lock Screen or a Live Activity.

## Product Purpose

37 Shades of Late shows the next departures for the lines and stops a rider saved, plus the actual vehicles on the way to them. Success means the rider glances, knows whether to leave now, and hardly needs to open the app.

## Positioning

- **Your stops, nothing else.** Favorites come first. There is no search-everything planner UI.
- **See the bus coming.** A live map of the route and the real vehicles headed to your stop, not just a list of minutes.
- **Glance, don't open.** Widgets, Lock Screen and Live Activities carry most of the use.
- **Hill-aware trips.** Regular commutes (home ⇄ work) are weighed by real walking effort: climbing is a hard penalty, going downhill is a small bonus, tuned by the app, not set by the user.

## Operating Context

- Used on the move, one-handed, often while walking or standing at a stop, and in passing from the Home Screen or Lock Screen.
- Favorites are full-screen maps you swipe through vertically. A favorites column on the left; on the right the ? and, under it, a city button (its code, a menu of your cities and "Choose Cities…"), which says "You're in <city>" when the IP guess puts you in another city.
- Trips: a home and a work place, with ways between them (one or two rides) found by the proxy's network search. Live re-checking on the train (where to get off or change, with a Live Activity alert) is planned.
- The app picks the nearer city from a rough IP guess; it asks for no location permission.

## Capabilities and Constraints

- Cities and feeds: Muni and BART (SF), King County Metro, Sound Transit and the Seattle Streetcar, New York subway, Staten Island Railway, PATH and buses, Boston (MBTA), LA Metro, and some ferries.
- Every request goes through the Cloudflare Worker proxy in `proxy/`, which holds the API keys and shares one snapshot between all users within each feed's rate budget.
- Line lists and line maps ship as offline snapshots and must load instantly without a network.
- Apple's map attribution stays visible on every map.
- Paid app, $0.99 once (App Store listing). Data used to track users: none.
- Terminology: "favorites" (a saved line + direction + stop), "trips" (home/work), "ways" (one suggested route of a trip), "felt minutes" (time with walking effort weighed in).

## Brand Commitments

- Name: **37 Shades of Late**, after the 37 Corbett bus in San Francisco. The title appears in the app.
- Voice: wry and irreverent about transit; the wait-time comments use mild profanity, which the App Store age rating accounts for.

## Evidence on Hand

- App Store screenshots: `AppStore/screenshots/` (iPhone 6.3", iPad 13"), a review demo video `AppStore/review-demo.mp4`, and listing copy in `AppStore/listing.md`.
- Website images: `site/images/` (home, grid, picker, Lock Screen widget, cities map, screen captures).
- Usage stats from the app's own event log (`site/src/stats.html`).
- No testimonials, press or ratings on hand; do not invent any.

## Product Principles

1. The answer is a number of minutes at a glance; everything else is secondary.
2. Show real things: real vehicles, real streets, real hills. Don't hide uncertainty behind confident-looking estimates.
3. The rider never tunes the algorithm; the app dials in walking effort, waits and grouping.
4. Same-platform lines are one choice (J/K/L/M/N at Church), not five.
5. Free-tier data budgets are a product constraint: one shared fetch serves everyone.
