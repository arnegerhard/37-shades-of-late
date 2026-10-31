# App Store listing — 37 Shades of Late

Paste these into App Store Connect → your app → App Information / the 1.0 version page.

## App Information

| Field | Value |
| --- | --- |
| Name (≤30) | 37 Shades of Late |
| Subtitle (≤30) | SF, Seattle, NYC & Boston |
| Bundle ID | info.jetsons.bus37 |
| SKU | 37shadesoflate-1 |
| Primary category | Navigation |
| Secondary category | Travel |
| Content rights | Does not contain, show, or access third-party content* |
| Age rating | Answer **Profanity or Crude Humor: Infrequent/Mild** (the wait-time comments say "shit" and "bastard"), "None" to everything else; Apple then sets the rating |
| Price | $0.99 (Tier 1) |

\* The departure times come from public transit data feeds, credited in the description and on the
privacy page: 511.org's open data API (Muni), OneBusAway Puget Sound (Seattle), MTA's GTFS-realtime
feeds and MTA Bus Time (New York subway and buses), BART's GTFS-realtime feed, the MBTA's V3 API and
GTFS-realtime feeds (Boston), the ferry operators' GTFS feeds, and the Port Authority's
RidePATH feed (PATH). All but the last are published open-data services for developers. The RidePATH
feed is the one the Port Authority's own app uses, not a published developer service, so if App Review
asks specifically about PATH, that's the weak spot (see "Data sources" below).

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

> Your bus, train or ferry, at a glance. San Francisco, Seattle, New York and Boston departures on your Lock Screen, live, with an honest opinion about the wait.

**Description (≤4000)**

> 37 Shades of Late puts the next departures where you'll actually see them: on your Lock Screen and Home Screen. Raise your phone, see the minutes, put it back.
>
> Tap your line on a map of the whole city, tap the arrow at your stop, done. It's saved as a favorite, and your widgets show your favorites in the order you choose.
>
> • San Francisco: every Muni bus, streetcar and Metro line, plus BART
> • Seattle: King County Metro (including RapidRide), Sound Transit Link and ST Express, and the Seattle Streetcar
> • New York: every subway line, the Staten Island Railway, PATH, and MTA buses
> • Boston: the MBTA's Red, Orange, Blue and Green Lines, the Silver Line, buses, commuter rail and ferries
> • Ferries in every city: Golden Gate and SF Bay Ferry, Washington State Ferries, NYC Ferry, NY Waterway and the Staten Island Ferry
> • A favorites list per city; swipe between cities
> • Widgets show the favorites of the city you're in, no location permission needed
> • Minutes, not clock times: "4 min" beats "10:52" when you're deciding whether to run
> • Live predictions in green, scheduled times in grey
> • A map of the route and where your bus is right now
> • "Also fine with": add the other lines at your stop, or one a short walk away, and see them all as one
> • Lock Screen widgets: under the clock, above it, or a single countdown in a circle; Home Screen widgets in two sizes
> • Comments on every wait, from "Holy shit, the 37 is real" to "Walking is starting to look attractive"
> • No account, no ads, no tracking
>
> Departure data from 511.org, OneBusAway, the MTA, BART, the MBTA, the Port Authority of New York and New Jersey, and the ferry operators. 37 Shades of Late is an independent app and is not affiliated with or endorsed by SFMTA, the Metropolitan Transportation Commission, BART, King County Metro, Sound Transit, the MTA, the MBTA, the Port Authority of New York and New Jersey, or any ferry operator.

**Keywords (≤100, comma-separated, no space after commas)**

> muni,bart,seattle,nyc,boston,mbta,subway,bus,transit,ferry,mta,widget,lock screen,departures,sf

**What's New**

> Now in Boston: the MBTA's subway, Silver Line, buses, commuter rail and ferries. Plus ferries in every city, the island and Lock Screen watching your stop live, and a circle on the map to pick your stop.

**Copyright**

> 2026 Arne Gerhard

## App Review notes

> 37 Shades of Late shows when the next buses and trains leave a stop the user picks, in San Francisco (Muni and BART), Seattle, New York (subway, PATH and MTA buses) and Boston (MBTA), in the app and in Home Screen and Lock Screen widgets. There's no login, account or purchase inside the app.
>
> To try it: the app opens on the main screen with a map of a stop near the top. Tap Find a stop on the map (to try a stop, with a + by it to keep it) or + next to Favorites (to keep it right away) to see every line in the city on a map. Tap a line, then tap the white arrow at a stop for that stop and direction (or use the list button to pick by name), then Choose. The stop is saved as a favorite and shown on the map, with its route and the vehicles on their way (pinch to zoom, two fingers to move it), and in the Favorites list with the next departures. Swipe left or right to switch city; each city has its own favorites. Holding a favorite offers Share and Delete; holding its handle on the right drags it to reorder.
>
> The widgets show the favorites of the city the device is in. The app has no location permission: the city is a rough guess from the network address, made by our server and not stored. On first launch the app starts in the nearest city at a default stop (line 37 at 14th St & Church St in San Francisco, route 8 at Denny Way & Fairview Ave in Seattle, the G at Metropolitan Av in New York, the Red Line at Park Street in Boston) and offers a 30-second walkthrough for adding the Lock Screen widget.
>
> Departure times come from our caching server in front of public transit data feeds: 511.org (Muni), OneBusAway Puget Sound (Seattle), the MTA's real-time feeds and MTA Bus Time (New York), BART's real-time feed, the MBTA's API and real-time feeds (Boston), the ferry operators' published schedules and feeds, and the Port Authority's RidePATH feed (PATH). The short comments on each wait ("Stay put, lazy bastard.") are the app's tone; they are the reason for the mild crude-humor age rating.
>
> A screen recording of these steps is attached.

## Data sources

| City | Service | Source | Key |
| --- | --- | --- | --- |
| San Francisco | Muni | 511.org open data API | `API_KEY_511` secret |
| San Francisco | BART | BART GTFS-realtime (api.bart.gov) | none |
| Seattle | Metro, Sound Transit, Streetcar | OneBusAway Puget Sound | `OBA_API_KEY` secret |
| New York | Subway, Staten Island Railway | MTA GTFS-realtime (api-endpoint.mta.info) | none |
| New York | Buses | MTA Bus Time (OneBusAway and SIRI) | `MTA_BUSTIME_KEY` secret |
| New York | PATH | Port Authority RidePATH feed (panynj.gov) | none |
| New York | NYC Ferry, NY Waterway, Staten Island Ferry | Operators' GTFS and GTFS-realtime | none |
| Boston | Subway, buses, commuter rail, ferries | MBTA GTFS-realtime (cdn.mbta.com) and V3 API (api-v3.mbta.com) | optional `MBTA_API_KEY` secret |
| San Francisco | Golden Gate Ferry, SF Bay Ferry | Operators' GTFS and GTFS-realtime | none |
| Seattle | Washington State Ferries | WSDOT GTFS | none |

Each agency's open-data terms ask for credit, given in the description and on the privacy page. The PATH
feed isn't a published developer service; if App Review questions it, PATH can be left out of a release
without touching the other cities.

## Demo video

`AppStore/review-demo.mp4`: a short screen recording of the steps in the review notes, for the attachment
field under App Review Information.

## Screenshots

In `AppStore/screenshots/`, from `AppStore/capture.sh` (it seeds the same favorites in every city each run; the
seventh shot is New York). App Store Connect's "iPhone with Dynamic Island (medium display)" tab takes the
`iphone-6.3` set (1206×2622); "iPad 13\" display" takes the `ipad-13` set (2064×2752). The `iphone-6.9` set
(1320×2868) is for a large-display tab if Apple asks for one.
