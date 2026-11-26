#!/usr/bin/env python3 -I
"""
Builds proxy/src/path-schedule.json: PATH's regular timetable from its GTFS, the stand-in for the one src/path-timetable.ts
reads each day from the Port Authority's schedule pages, while those can't be had. For each day type (weekday,
Saturday, Sunday), each line's departures from each platform, coded as nyc-subway.json's ("PATH-862" from
"PGRVY"), as seconds after midnight with the platform the train ends at.

Only the three year-round services are read, not the feed's construction and holiday specials. The Port Authority
publishes the feed about every six months (www.panynj.gov/path/download-schedules.html); its mirrors' copy ran out
on June 1, 2026, so these are last year's times. Runs by hand, from the mirror or a feed already downloaded:

    python3 -I proxy/scripts/path-schedule.py [path-gtfs.zip]
"""

import importlib.util, io, json, os, sys, urllib.request, zipfile
from collections import defaultdict

# PATH_GTFS, PATH_STATIONS, PATH_LINES and read(), as the network's build has them.
sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("nyc_subway", os.path.join(HERE, "nyc-subway.py"))
nyc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nyc)

OUT = os.path.join(HERE, "..", "src", "path-schedule.json")
DAYS = {"weekday": "monday", "saturday": "saturday", "sunday": "sunday"}


def main():
    if len(sys.argv) > 1:
        data = open(sys.argv[1], "rb").read()
    else:
        with urllib.request.urlopen(nyc.PATH_GTFS) as response:
            data = response.read()
    z = zipfile.ZipFile(io.BytesIO(data))
    stops = {s["stop_id"]: s for s in nyc.read(z, "stops.txt")}
    station = lambda stop_id: nyc.PATH_STATIONS[(stops.get(stops[stop_id]["parent_station"]) or stops[stop_id])["stop_name"]]

    # The year-round services ("Year Round Starting 3/16/2025 (Weekday)"), by the day they run.
    services = {}
    for c in nyc.read(z, "calendar.txt"):
        if c["service_name"].startswith("Year Round"):
            for day, column in DAYS.items():
                if c[column] == "1":
                    services[c["service_id"]] = day
    trips = {t["trip_id"]: t for t in nyc.read(z, "trips.txt") if t["service_id"] in services and t["route_id"] in nyc.PATH_LINES}

    times = defaultdict(list)
    for st in nyc.read(z, "stop_times.txt"):
        if st["trip_id"] in trips:
            h, m, s = map(int, (st["departure_time"] or st["arrival_time"]).split(":"))
            times[st["trip_id"]].append((int(st["stop_sequence"]), station(st["stop_id"]), h * 3600 + m * 60 + s))

    schedule = {day: defaultdict(list) for day in DAYS}
    for trip_id, stops_at in times.items():
        trip = trips[trip_id]
        way = "Y" if trip["direction_id"] == "1" else "J"
        stops_at.sort()
        end = f"P{stops_at[-1][1]}{way}"
        # Not where it ends: nobody gets on there.
        for _, code, seconds in stops_at[:-1]:
            schedule[services[trip["service_id"]]][f"PATH-{trip['route_id']}|P{code}{way}"].append([seconds, end])
    for day in schedule.values():
        for departures in day.values():
            departures.sort()
    feed = {f["feed_end_date"] for f in nyc.read(z, "feed_info.txt")} if "feed_info.txt" in z.namelist() else set()
    with open(OUT, "w") as f:
        json.dump({"until": min(feed, default=""), "days": schedule}, f, separators=(",", ":"))
    print(sum(len(d) for day in schedule.values() for d in day.values()), "departures,",
          os.path.getsize(OUT) // 1024, "KB ->", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
