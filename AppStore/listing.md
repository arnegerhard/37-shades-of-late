# App Store listing — 37 Shades of Late

Paste these into App Store Connect → your app → App Information / the 1.0 version page.

## App Information

| Field | Value |
| --- | --- |
| Name (≤30) | 37 Shades of Late |
| Subtitle (≤30) | SF & Seattle bus times, live |
| Bundle ID | info.jetsons.bus37 |
| SKU | 37shadesoflate-1 |
| Primary category | Navigation |
| Secondary category | Travel |
| Content rights | Does not contain, show, or access third-party content* |
| Age rating | Answer **Profanity or Crude Humor: Infrequent/Mild** (the wait-time comments say "shit" and "bastard"), "None" to everything else; Apple then sets the rating |
| Price | $0.99 (Tier 1) |

\* The departure times come from the public 511.org open data API, which permits redistribution
with attribution (given in the description and on the privacy page). If App Review asks, that's
the answer.

## URLs

| Field | Value |
| --- | --- |
| Privacy Policy URL | https://37shadesoflate.com/privacy |
| Support URL | https://37shadesoflate.com/support |
| Marketing URL | https://37shadesoflate.com |

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

> Your bus, at a glance. Pick any line and stop in San Francisco or Seattle, then see the next departures right on your Home Screen and Lock Screen, live.

**Description (≤4000)**

> 37 Shades of Late puts the next San Francisco Muni and Seattle transit departures where you'll actually see them: on your Home Screen and Lock Screen.
>
> Pick your line, direction and stop once. The widgets then show when the next buses leave — as clock times and minutes away — so you know whether to walk or run without opening an app.
>
> • San Francisco: every Muni bus, rapid, express, streetcar and Metro line
> • Seattle: King County Metro (including RapidRide), Sound Transit Link, Sounder and ST Express, and the Seattle Streetcar
> • Starts in the city you're closest to, no location permission needed
> • Search lines by number or name, and stops by street
> • Live predictions, shown in green, with scheduled times for buses that haven't started their trip yet
> • Live map with the route and where your bus is right now
> • Home Screen widgets in small and medium sizes, with a refresh button
> • Lock Screen widgets: next two departures, minutes to the next bus, or a one-line summary above the clock
> • No account, no ads, no tracking
>
> Departure data from 511.org and OneBusAway. 37 Shades of Late is an independent app and is not affiliated with or endorsed by SFMTA, the Metropolitan Transportation Commission, King County Metro or Sound Transit.

**Keywords (≤100, comma-separated, no space after commas)**

> muni,seattle,bus,sf,san francisco,transit,king county metro,sound transit,link,widget,arrival

**What's New**

> First release. Now with Seattle.

**Copyright**

> 2026 Arne Gerhard

## App Review notes

> The app needs no login. Open it, tap the line at the top, pick San Francisco or Seattle, then any line, direction and stop; the departure list and the widgets update to that stop. On first launch it starts in the city nearest to the device's rough network location (from our server, no location permission): line 37 at 14th St & Church St in San Francisco, or route 8 at Denny Way & Fairview Ave in Seattle. Departure times come from our caching server in front of 511.org (San Francisco) and OneBusAway (Seattle).

## Screenshots

In `AppStore/screenshots/`. App Store Connect's "iPhone with Dynamic Island (medium display)" tab takes the
`iphone-6.3` set (1206×2622); "iPad 13\" display" takes the `ipad-13` set (2064×2752). The `iphone-6.9` set
(1320×2868) is for a large-display tab if Apple asks for one.
