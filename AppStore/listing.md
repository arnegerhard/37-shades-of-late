# App Store listing — 37 Shades of Late

Paste these into App Store Connect → your app → App Information / the 1.1 version page (the first release:
1.0 was never released, its version page renamed 1.1).

## App Information

| Field | Value |
| --- | --- |
| Name (≤30) | 37 Shades of Late |
| Subtitle (≤30) | Next bus & train, at a glance |
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
GTFS-realtime feeds (Boston), the CTA's Train Tracker and Bus Tracker (Chicago), WMATA's GTFS-realtime
feeds (Washington), LA Metro's real-time feeds via Swiftly (Los Angeles), the ferry operators' GTFS
feeds, and the Port Authority's RidePATH feed (PATH). All but the last are published open-data services for developers. The RidePATH
feed is the one the Port Authority's own app uses, not a published developer service, so if App Review
asks specifically about PATH, that's the weak spot (see "Data sources" below).

## URLs

| Field | Value |
| --- | --- |
| Privacy Policy URL | https://37shadesoflate.com/privacy |
| Support URL | https://37shadesoflate.com/support |
| Marketing URL | https://37shadesoflate.com |

## App Privacy ("nutrition label")

Data used to track you: **none** (a label that said otherwise got 1.0 rejected under 5.1.2(i) on Nov 7).
As published in App Store Connect since Nov 9, all "Data Not Linked to You":

| Data type | Collected | Linked to the user | Used for tracking | Purpose |
| --- | --- | --- | --- | --- |
| Location → Coarse Location | Yes | **No** | No | App Functionality |
| Usage Data → Product Interaction | Yes | **No** | No | Analytics |
| Diagnostics → Crash Data | Yes | **No** | No | Analytics |

Coarse location is the server's rough guess from the network address (which city, how far from it),
not stored; the app asks for no location permission. Product interaction comes with a random install ID
the app makes itself (not the IDFA or IDFV), which nothing ties to a person, and which never leaves this
app, so it isn't tracking and no App Tracking Transparency prompt is needed.

## Version 1.1

**Promotional text (≤170)**

> Your bus, train or ferry at a glance, live on your Lock Screen, in San Francisco, Seattle, New York, Boston, Chicago, Washington and LA. With opinions.

**Description (≤4000)**

> 37 Shades of Late puts the next departures where you'll actually see them: on your Lock Screen and Home Screen. Raise your phone, see the minutes, put it back.
>
> Finding your stop takes seconds: the city's lines on a map, a circle you slide over the corner where you wait, and every line that stops there with its next departures. Pick yours and which way, tap +, done. Keep as many as you like; your widgets show them in the order you choose.
>
> Every stop you keep gets the whole screen: a live map of its route and the actual buses and trains on their way to you. Swipe up for the next one.
>
> • San Francisco: every Muni bus, streetcar and Metro line, BART, and the Golden Gate and San Francisco Bay ferries
> • Seattle: King County Metro (including RapidRide), Sound Transit Link and ST Express, the Seattle Streetcar and Washington State Ferries
> • New York: every subway line, the Staten Island Railway, PATH, MTA buses, NYC Ferry, NY Waterway and the Staten Island Ferry
> • Boston: the MBTA's subway, Silver Line, buses, commuter rail and ferries
> • Chicago: the CTA's 'L' and buses
> • Washington, D.C.: Metrorail and Metrobus
> • Los Angeles: LA Metro's rail lines, busways and buses
> • Pick the cities you ride in; the city button switches between them, and the app notices when you're in another one, no location permission needed
> • Widgets show the stops of the city you're in
> • Minutes, not clock times: "4 min" beats "10:52" when you're deciding whether to run
> • Live predictions in green, scheduled times in grey
> • Watch your stop from the Dynamic Island and Lock Screen while you finish your coffee
> • "Also fine with": add the other lines at your stop, or one a short walk away, and see them all as one
> • Lock Screen widgets: under the clock, above it, or a single countdown in a circle; Home Screen widgets in two sizes
> • Share a stop as a link that shows its live wait to anyone, app or not
> • Comments on every wait, from "Holy shit, the 37 is real" to "Walking is starting to look attractive"
> • No account, no ads, no tracking
>
> Departure data from 511.org, OneBusAway, the MTA, BART, the MBTA, the CTA, WMATA, LA Metro, the Port Authority of New York and New Jersey, and the ferry operators. 37 Shades of Late is an independent app and is not affiliated with or endorsed by SFMTA, the Metropolitan Transportation Commission, BART, King County Metro, Sound Transit, the MTA, the MBTA, the CTA, WMATA, LA Metro, the Port Authority of New York and New Jersey, or any ferry operator.

**Keywords (≤100, comma-separated, no space after commas)**

> muni,bart,nyc,mbta,cta,wmata,metro,subway,bus,ferry,transit,widget,lock screen,departures

**Copyright**

> 2026 Arne Gerhard

## App Review notes

> 37 Shades of Late shows when the next buses, trains and ferries leave the stops the user picks, in San Francisco, Seattle, New York, Boston, Chicago, Washington D.C. and Los Angeles: in the app, in Home Screen and Lock Screen widgets, and in a Live Activity. There's no login, account or in-app purchase.
>
> To try it: on first launch a short walkthrough explains the Lock Screen widget (Skip is top right), then a map of the cities, with the nearest one picked from a rough guess of the network address (the app asks for no location permission); tap Start suffering. The city's lines open on a map. Tap the map or pinch to zoom in until stops appear, slide the map so a corner sits in the blue circle, and pick a line and direction from the list at the bottom. The stop opens full screen with its route and the vehicles on their way; tap + next to its name to keep it as a favorite.
>
> Favorites line up in the column on the left: tap one to open it, swipe up and down between them, or hold one to reorder it or drop it on the bin. The magnifying glass at the top of the column finds another stop. The round button under the ? switches city; its pencil chooses cities. Tap the pill with the line and minutes to watch the stop on the Dynamic Island and Lock Screen (a Live Activity), and tap it again to stop. The paper plane shares the stop as a web link. The ? explains adding the widgets.
>
> The widgets show the favorites of the city the device is in, guessed by our server from the network address and not stored. Departure times come from our caching server in front of public transit data feeds: 511.org (Muni), BART's real-time feed, OneBusAway Puget Sound (Seattle), the MTA's real-time feeds and MTA Bus Time (New York), the Port Authority's RidePATH feed (PATH), the MBTA's API and feeds (Boston), the CTA's Train Tracker and Bus Tracker (Chicago), WMATA's feeds (Washington), LA Metro's feeds (Los Angeles), and the ferry operators' schedules and feeds. The short comments on each wait ("Stay put, lazy bastard.") are the app's tone; they are the reason for the mild crude-humor age rating.
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
| Chicago | 'L' trains | CTA Train Tracker | `CTA_API_KEY` secret |
| Chicago | Buses | CTA Bus Tracker | `CTA_BUS_KEY` secret |
| Washington | Metrorail, Metrobus | WMATA GTFS-realtime | `WMATA_API_KEY` secret |
| Los Angeles | Metro rail, busways, buses | LA Metro GTFS-realtime via Swiftly (else Metro's WebSockets) | optional `SWIFTLY_API_KEY` secret |

Each agency's open-data terms ask for credit, given in the description and on the privacy page. The PATH
feed isn't a published developer service; if App Review questions it, PATH can be left out of a release
without touching the other cities.

## Demo video

`AppStore/review-demo.mp4`: a short screen recording of the steps in the review notes, for the attachment
field under App Review Information.

## Screenshots

In `AppStore/screenshots/`, from `AppStore/capture.sh <simulator-udid> <prefix>` (it seeds the same favorites in
every city, hides the tips, and shoots home, the lines map, a line's stops, the widgets, the Lock Screen and New
York). Run it while the 37 is running (not before 6 AM in San Francisco), so the shots have real minutes.
App Store Connect's "iPhone with Dynamic Island (medium display)" tab takes the `iphone-6.3` set (1206×2622,
iPhone 17); "iPad 13\" display" takes the `ipad-13` set (2064×2752, iPad Pro 13-inch). Smaller devices are
scaled from these.
