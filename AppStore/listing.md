# App Store listing — 37 Shades of Late

Paste these into App Store Connect → your app → App Information / the 1.0 version page.

## App Information

| Field | Value |
| --- | --- |
| Name (≤30) | 37 Shades of Late |
| Subtitle (≤30) | Muni times on your Lock Screen |
| Bundle ID | info.jetsons.bus37 |
| SKU | 37shadesoflate-1 |
| Primary category | Navigation |
| Secondary category | Travel |
| Content rights | Does not contain, show, or access third-party content* |
| Age rating | 4+ (answer "None" to every question) |
| Price | Free |

\* The departure times come from the public 511.org open data API, which permits redistribution
with attribution (given in the description and on the privacy page). If App Review asks, that's
the answer.

## URLs

| Field | Value |
| --- | --- |
| Privacy Policy URL | https://bus37-proxy.arne-5c1.workers.dev/privacy |
| Support URL | https://bus37-proxy.arne-5c1.workers.dev/support |
| Marketing URL | (leave empty) |

## App Privacy ("nutrition label")

Data used to track you: **none**. Answer the questionnaire like this:

| Data type | Collected | Linked to the user | Used for tracking | Purpose |
| --- | --- | --- | --- | --- |
| Usage Data → Product Interaction | Yes | **No** | No | Analytics |
| Identifiers → Device ID | Yes | **No** | No | Analytics |

The "Device ID" is the random install ID the app generates itself (not the IDFA or IDFV), sent
with each request together with which screen made it and the line/stop viewed. Nothing ties it
to a person, so it is "Not Linked to You", and it never leaves this app, so it isn't tracking
and no App Tracking Transparency prompt is needed. Everything else: not collected.

## Version 1.0

**Promotional text (≤170)**

> Your bus, at a glance. Pick any Muni line and stop, then see the next departures right on your Home Screen and Lock Screen — live from the bus's GPS.

**Description (≤4000)**

> 37 Shades of Late puts the next San Francisco Muni departures where you'll actually see them: on your Home Screen and Lock Screen.
>
> Pick your line, direction and stop once. The widgets then show when the next buses leave — as clock times and minutes away — so you know whether to walk or run without opening an app.
>
> • Every Muni bus, rapid, express, streetcar and Metro line
> • Search lines by number or name, and stops by street
> • Live GPS predictions, shown in green, with scheduled times for buses that haven't left yet
> • Home Screen widgets in small and medium sizes, with a refresh button
> • Lock Screen widgets: next two departures, minutes to the next bus, or a one-line summary above the clock
> • No account, no ads, no tracking
>
> Departure data from 511.org. 37 Shades of Late is an independent app and is not affiliated with or endorsed by SFMTA or the Metropolitan Transportation Commission.

**Keywords (≤100, comma-separated, no space after commas)**

> muni,bus,sf,san francisco,transit,widget,lock screen,arrival,departure,streetcar,commute,metro

**What's New**

> First release.

**Copyright**

> 2026 <your name or company>

## App Review notes

> The app needs no login. Open it, tap the line at the top to choose any Muni line, direction and stop; the departure list and the widgets update to that stop. Default is line 37 at 14th St & Church St. Departure times come from our caching server in front of the 511.org public transit API.

## Screenshots

In `AppStore/screenshots/` — upload the `iphone-6.9` set (1320×2868) and the `ipad-13` set (2064×2752).
