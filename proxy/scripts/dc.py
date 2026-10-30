#!/usr/bin/env python3 -I
"""
Builds proxy/src/dc.json from WMATA's static GTFS, Metrorail's and Metrobus's: every line with its stops in
order per direction (the common patterns merged), where each way ends up, simplified shapes and colors, as
chicago.py does for Chicago. WMATA's feeds take its API key (WMATA_API_KEY, from developer.wmata.com), and
the network changes a few times a year, so this runs by hand:

    WMATA_API_KEY=... python3 -I proxy/scripts/dc.py

or from feeds already downloaded: python3 -I proxy/scripts/dc.py rail.zip bus.zip

Live departures come from WMATA's GTFS-realtime feeds at request time (see src/dc.ts).
"""

import csv, importlib.util, io, json, os, re, sys, urllib.request, zipfile
from collections import Counter, defaultdict

# Loading chicago.py below would leave its bytecode next to it.
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "src", "dc.json")
API = "https://api.wmata.com/"

# simplify() and merge_runs(), as Chicago's.
spec = importlib.util.spec_from_file_location("chicago", os.path.join(HERE, "chicago.py"))
chicago = importlib.util.module_from_spec(spec)
spec.loader.exec_module(chicago)

# Metrorail in the order its map lists them.
RAIL = ["Red", "Orange", "Blue", "Silver", "Green", "Yellow"]
COMMON = 0.1


def get(path, key):
    request = urllib.request.Request(API + path, headers={"api_key": key, "User-Agent": "37 Shades of Late"})
    return urllib.request.urlopen(request).read()


def station_names(key):
    """Metrorail's stations as WMATA writes them ("Foggy Bottom-GWU"), by their codes; the GTFS has them in
    capitals. Without a key, the GTFS's names, capitalized as words."""
    if not key:
        return {}
    stations = json.loads(get("Rail.svc/json/jStations", key))["Stations"]
    return {s["Code"]: s["Name"] for s in stations}


def titled(name):
    small = {"NW", "NE", "SW", "SE", "GWU", "UDC", "VA", "MD", "DC", "II"}
    name = re.sub(r"\s+METRORAIL STATION\s*$", "", name.strip(), flags=re.I)
    return re.sub(r"[A-Za-z']+", lambda m: m[0] if m[0] in small else m[0].capitalize(), name)


def read_feed(data, rail, names):
    archive = zipfile.ZipFile(io.BytesIO(data))
    read = lambda name: csv.DictReader(io.TextIOWrapper(archive.open(name), encoding="utf-8-sig"))
    routes = list(read("routes.txt"))
    stops = {s["stop_id"]: s for s in read("stops.txt")}
    trips = {t["trip_id"]: t for t in read("trips.txt")}

    def stop_name(stop_id):
        stop = stops[stop_id]
        if not rail:
            return stop["stop_name"]
        station = stop.get("parent_station") or stop_id
        # "STN_A01_C01": Metro Center, A01 (and C01, its lower level).
        code = station.split("_")[1] if station.startswith("STN_") else ""
        return names.get(code) or titled(stops.get(station, stop)["stop_name"])

    print("Reading stop times")
    sequences = defaultdict(list)
    for row in read("stop_times.txt"):
        sequences[row["trip_id"]].append((int(row["stop_sequence"]), row["stop_id"]))

    patterns = defaultdict(Counter)
    shape_of, headsigns = {}, defaultdict(Counter)
    for trip_id, seq in sequences.items():
        trip = trips.get(trip_id)
        if not trip:
            continue
        run = tuple(s for _, s in sorted(seq))
        key = (trip["route_id"], trip["direction_id"])
        patterns[key][run] += 1
        shape_of.setdefault((key, run), trip["shape_id"])
        headsigns[key][trip.get("trip_headsign", "")] += 1
    sequences.clear()

    print("Reading shapes")
    shapes = defaultdict(list)
    for row in read("shapes.txt"):
        shapes[row["shape_id"]].append((int(row["shape_pt_sequence"]), float(row["shape_pt_lat"]), float(row["shape_pt_lon"])))

    lines = []
    for route in routes:
        rid = route["route_id"]
        directions = []
        for direction in ("0", "1"):
            counted = patterns.get((rid, direction))
            if not counted:
                continue
            top = counted.most_common(1)[0][1]
            common = [run for run, n in counted.most_common() if n >= top * COMMON][:6]
            order = chicago.merge_runs([list(r) for r in common])
            end = Counter(run[-1] for run in common).most_common(1)[0][0]
            # A bus's headsign says where it's going ("East to Congress Heights"); a train's way is
            # where its line ends.
            sign = headsigns[(rid, direction)].most_common(1)[0][0]
            destination = stop_name(end) if rail or not sign else re.sub(r"^\w+ to ", "", sign).strip()
            drawn = []
            for run in common[:3]:
                points = sorted(shapes.get(shape_of[((rid, direction), run)], []))
                if len(points) > 1:
                    drawn.append(chicago.simplify([(lat, lon) for _, lat, lon in points]))
            directions.append({
                "id": direction,
                "destination": destination,
                "stops": [[s, stop_name(s), round(float(stops[s]["stop_lat"]), 5), round(float(stops[s]["stop_lon"]), 5)]
                          for s in order if s in stops],
                "shapes": drawn,
            })
        if not directions:
            continue
        # Metrorail by its color ("Red"; its short name is just "R"), buses by their numbers.
        line_id = route["route_long_name"] if rail else route["route_short_name"] or rid
        lines.append({
            "id": line_id,
            "name": f"{line_id} Line" if rail else (route["route_long_name"] or line_id).title(),
            "mode": "subway" if rail else "bus",
            "routeId": rid,
            "color": f"#{route['route_color'].upper()}" if route["route_color"] else None,
            "textColor": f"#{route['route_text_color'].upper()}" if route["route_text_color"] else None,
            "directions": directions,
        })
    return lines


def main():
    key = os.environ.get("WMATA_API_KEY", "")
    if len(sys.argv) == 3:
        rail, bus = (open(path, "rb").read() for path in sys.argv[1:])
    elif key:
        print("Downloading WMATA's GTFS")
        rail, bus = get("gtfs/rail-gtfs-static.zip", key), get("gtfs/bus-gtfs-static.zip", key)
    else:
        sys.exit("Set WMATA_API_KEY, or pass the rail and bus GTFS zips")
    names = station_names(key)
    lines = read_feed(rail, True, names) + read_feed(bus, False, names)

    # Metrorail first, in the map's order, then buses by name.
    key_of = lambda l: (0, RAIL.index(l["id"]), "") if l["id"] in RAIL else (1, 0, l["id"])
    lines.sort(key=key_of)
    with open(OUT, "w") as f:
        json.dump({"lines": lines}, f, separators=(",", ":"))
    print(len(lines), "lines,", os.path.getsize(OUT) // 1024, "KB ->", OUT)


if __name__ == "__main__":
    main()
