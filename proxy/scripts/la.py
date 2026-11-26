#!/usr/bin/env python3 -I
"""
Builds proxy/src/la.json from LA Metro's static GTFS, rail and bus (both public on GitLab): every line with its
stops in order per direction (the common patterns merged), where each way ends up, simplified shapes and colors,
as chicago.py does for Chicago. The bus schedule alone is 300 MB unpacked, and the network changes a few times a
year, so this runs by hand:

    python3 -I proxy/scripts/la.py

or from feeds already downloaded: python3 -I proxy/scripts/la.py rail.zip bus.zip

Live departures come from Metro's GTFS-realtime feeds, through Swiftly, at request time (see src/la.ts).

Also the county's other bus operators with open GTFS-realtime feeds (OPERATORS below: Beach Cities Transit down
Hermosa Ave, Big Blue Bus, DASH, Long Beach Transit and so on), their lines as "BCT 109", "BBB 7", "DASH A", their
stops as "BCT_1234", so nothing collides with Metro's or each other's. Each operator's feeds go into la.json too,
with which line each of its routes is, for src/la-munis.ts to match their live trips to lines with. Their schedules
change every few months (some end in weeks), but their lines and stops rarely; run this again when one does. Not
Torrance Transit or Glendale's Beeline (their sites turn scripts away), nor those without live times (Lawndale Beat,
PV Transit).
"""

import csv, importlib.util, io, json, os, re, sys, urllib.request, zipfile
from collections import Counter, defaultdict

# Loading chicago.py below would leave its bytecode next to it.
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "src", "la.json")
FEEDS = {"rail": "https://gitlab.com/LACMTA/gtfs_rail/raw/master/gtfs_rail.zip",
         "bus": "https://gitlab.com/LACMTA/gtfs_bus/raw/master/gtfs_bus.zip"}

# simplify() and merge_runs(), as Chicago's.
spec = importlib.util.spec_from_file_location("chicago", os.path.join(HERE, "chicago.py"))
chicago = importlib.util.module_from_spec(spec)
spec.loader.exec_module(chicago)

# Metro Rail and the busways, by their letters, in the order Metro's map lists them.
LETTERS = ["A", "B", "C", "D", "E", "K", "G", "J"]
COMMON = 0.1
SMALL = {"via", "and", "to", "of", "the"}
CAPITALS = {"la", "dtla", "lax", "ucla", "usc", "csun", "va", "lacc", "elac", "cal", "ii"}


def titled(text):
    """"WESTWOOD - EXPOSITION PARK VIA SUNSET-ALVARADO" as people write it."""
    def word(m):
        w = m[0].lower()
        return w if w in SMALL else w.upper() if w in CAPITALS else w.capitalize()
    words = re.sub(r"[A-Za-z0-9']+", word, text.strip())
    return words[:1].upper() + words[1:]


def read_feed(data, rail):
    archive = zipfile.ZipFile(io.BytesIO(data))
    read = lambda name: csv.DictReader(io.TextIOWrapper(archive.open(name), encoding="utf-8-sig"))
    routes = list(read("routes.txt"))
    stops = {s["stop_id"]: s for s in read("stops.txt")}
    trips = {t["trip_id"]: t for t in read("trips.txt")}

    def stop_name(stop_id):
        stop = stops[stop_id]
        # A rail platform by its station's name, without the "Station" every one has (but Union Station's).
        station = stops.get(stop.get("parent_station") or "", stop) if rail else stop
        name = station["stop_name"].strip()
        return name if name == "Union Station" else re.sub(r"\s+Station$", "", name)

    def is_layover(stop_id):
        """Where buses wait between trips, which nobody's going to: "Arden Layover", "Terminal 28 - West Lot"."""
        return re.search(r"Layover|Terminal \d+|\bLot\b", stops[stop_id]["stop_name"]) is not None

    print("Reading stop times")
    sequences = defaultdict(list)
    for row in read("stop_times.txt"):
        sequences[row["trip_id"]].append((int(row["stop_sequence"]), row["stop_id"]))

    patterns = defaultdict(Counter)
    shape_of = {}
    for trip_id, seq in sequences.items():
        trip = trips.get(trip_id)
        if not trip:
            continue
        run = tuple(s for _, s in sorted(seq))
        key = (trip["route_id"], trip["direction_id"])
        patterns[key][run] += 1
        shape_of.setdefault((key, run), trip["shape_id"])
    sequences.clear()

    print("Reading shapes")
    shapes = defaultdict(list)
    for row in read("shapes.txt"):
        shapes[row["shape_id"]].append((int(row["shape_pt_sequence"]), float(row["shape_pt_lat"]), float(row["shape_pt_lon"])))

    lines = []
    for route in routes:
        rid = route["route_id"]
        # "Metro A Line", "Metro G Line (Orange) 901": a letter; buses by their numbers ("2", "10/48").
        letter = re.match(r"Metro ([A-Z]) Line", route["route_long_name"])
        line_id = letter[1] if letter else route["route_short_name"]
        if not line_id:
            continue
        directions = []
        for direction in ("0", "1"):
            counted = patterns.get((rid, direction))
            if not counted:
                continue
            top = counted.most_common(1)[0][1]
            common = [run for run, n in counted.most_common() if n >= top * COMMON][:6]
            order = chicago.merge_runs([list(r) for r in common])
            # Where it ends: the last stop people get off at, not the layover after it.
            end = Counter(next((s for s in reversed(run) if s in stops and not is_layover(s)), run[-1]) for run in common).most_common(1)[0][0]
            drawn = []
            for run in common[:3]:
                points = sorted(shapes.get(shape_of[((rid, direction), run)], []))
                if len(points) > 1:
                    drawn.append(chicago.simplify([(lat, lon) for _, lat, lon in points]))
            directions.append({
                "id": direction,
                "destination": stop_name(end),
                "stops": [[s, stop_name(s), round(float(stops[s]["stop_lat"]), 5), round(float(stops[s]["stop_lon"]), 5)]
                          for s in order if s in stops],
                "shapes": drawn,
            })
        if not directions:
            continue
        lines.append({
            "id": line_id,
            # "A Line"; a bus by where it runs ("Westwood - Exposition Park via Sunset-Alvarado").
            "name": f"{line_id} Line" if letter else titled(route["route_desc"] or route["route_long_name"] or line_id),
            # The B and D Lines run underground; the others are light rail, the G and J busways.
            "mode": ("subway" if route["route_type"] == "1" else "metro") if rail else "bus",
            "routeId": rid,
            "color": f"#{route['route_color'].upper()}" if route["route_color"] else None,
            "textColor": f"#{route['route_text_color'].upper()}" if route["route_text_color"] else None,
            "directions": directions,
        })
    return lines


# The county's other operators: key (the prefix of their lines' and stops' ids), name, static GTFS, live feeds, and
# how riders say a route ("BCT 109"). Routes it returns None for are left out.
def numbered(prefix):
    return lambda r: f"{prefix} {r['route_short_name']}" if r["route_short_name"] else None


def dash(r):
    """LADOT: Commuter Express by number ("CE 438B"), DASH by its letter or neighborhood ("DASH Crenshaw CW")."""
    long = r["route_long_name"].strip()
    if long.startswith("CE"):
        return f"CE {r['route_short_name']}"
    short = re.sub(r"Counter-?[Cc]lockwise|Counter-CW", "CCW", r["route_short_name"]).replace("Clockwise", "CW")
    return f"DASH {short}"


OPERATORS = [
    ("BCT", "Beach Cities Transit", "https://redondobeachbct.com/gtfs",
     "https://redondobeachbct.com/gtfs-rt/tripupdates", "https://redondobeachbct.com/gtfs-rt/vehiclepositions", numbered("BCT")),
    ("BBB", "Big Blue Bus", "https://www.bigbluebus.com/gtfs/current.zip",
     "https://cleverapi.bigbluebus.com/gtfsrt/trips", "https://cleverapi.bigbluebus.com/gtfsrt/vehicles", numbered("BBB")),
    ("CCB", "Culver CityBus", "https://web.culvercity.org/gtfs/gtfsexport.zip",
     "https://nextccbus.org/gtfsrt/trips", "https://nextccbus.org/gtfsrt/vehicles",
     lambda r: None if r["route_short_name"] == "9999" else f"Culver {r['route_short_name']}"),
    ("LADOT", "LADOT", "https://ladotbus.com/gtfs",
     "https://ladotbus.com/gtfs-rt/tripupdates", "https://ladotbus.com/gtfs-rt/vehiclepositions", dash),
    ("GT", "GTrans", "https://ridegtrans.com/gtfs.zip",
     "https://mygtbus.ridegtrans.com/gtfsrt/trips", "https://mygtbus.ridegtrans.com/gtfsrt/vehicles", numbered("GTrans")),
    # Where Long Beach Transit publishes it (its nationalrtap.org copy's certificate a Worker won't take).
    ("LBT", "Long Beach Transit", "https://drive.google.com/uc?export=download&id=1869EVa1z6m_iD6QmvRXyTHtYiaSUBROl",
     "https://gtfs-rt.lbt.vontascloud.com/TMGTFSRealTimeWebService/TripUpdate/TripUpdates.pb",
     "https://gtfs-rt.lbt.vontascloud.com/TMGTFSRealTimeWebService/Vehicle/VehiclePositions.pb", numbered("LBT")),
    ("FT", "Foothill Transit", "https://foothilltransit.rideralerts.com/myStop/GTFS-Zip.ashx",
     "https://foothilltransit.rideralerts.com/myStop/GTFS-Realtime.ashx?Type=TripUpdate",
     "https://foothilltransit.rideralerts.com/myStop/GTFS-Realtime.ashx?Type=VehiclePosition", numbered("Foothill")),
    ("MBL", "Montebello Bus Lines", "https://mbl.rideralerts.com/infopoint/gtfs-zip.ashx",
     "https://mbl.rideralerts.com/InfoPoint/GTFS-Realtime.ashx?Type=TripUpdate",
     "https://mbl.rideralerts.com/InfoPoint/GTFS-Realtime.ashx?Type=VehiclePosition",
     # No short names: "10 Whittier Blvd".
     lambda r: f"Montebello {r['route_long_name'].split()[0]}"),
    ("NTS", "Norwalk Transit", "https://nts.rideralerts.com/InfoPoint/gtfs-zip.ashx",
     "https://nts.rideralerts.com/InfoPoint/GTFS-Realtime.ashx?Type=TripUpdate",
     "https://nts.rideralerts.com/InfoPoint/GTFS-Realtime.ashx?Type=VehiclePosition", numbered("Norwalk")),
    ("PT", "Pasadena Transit", "https://rt.pasadenatransit.net/rtt/public/resource/gtfs.zip",
     "https://rt.pasadenatransit.net/rtt/public/utility/gtfsrealtime.aspx/tripupdate",
     "https://rt.pasadenatransit.net/rtt/public/utility/gtfsrealtime.aspx/vehicleposition", numbered("Pasadena")),
    ("BUR", "BurbankBus", "https://rideburbankbus.com/gtfs",
     "https://rideburbankbus.com/gtfs-rt/tripupdates", "https://rideburbankbus.com/gtfs-rt/vehiclepositions", numbered("Burbank")),
    ("SCT", "Santa Clarita Transit", "https://apps.santaclaritatransit.com/rtt/public/resource/gtfs.zip",
     "https://apps.santaclaritatransit.com/rtt/public/utility/gtfsrealtime.aspx/tripupdate",
     "https://apps.santaclaritatransit.com/rtt/public/utility/gtfsrealtime.aspx/vehicleposition", numbered("SCT")),
    ("AVTA", "Antelope Valley Transit", "https://track-it.avta.com/InfoPoint/gtfs-zip.ashx",
     "https://track-it.avta.com/InfoPoint/GTFS-Realtime.ashx?Type=TripUpdate",
     "https://track-it.avta.com/InfoPoint/GTFS-Realtime.ashx?Type=VehiclePosition", numbered("AVTA")),
    ("CMB", "Commerce Bus", "https://citycommbus.com/gtfs",
     "https://citycommbus.com/gtfs-rt/tripupdates", "https://citycommbus.com/gtfs-rt/vehiclepositions", numbered("Commerce")),
]


# Operators whose live feeds give only each bus's next stop (Connexionz's): src/la-munis.ts reads their schedules'
# times too, to carry that stop's delay on along the trip.
NEXT_STOP_ONLY = {"PT", "SCT"}


def stop_key(key, stop_id):
    """A stop's id as its live feed has it: Foothill's schedule has two agencies' copies of a stop ("3719-a1",
    "3719-a2"), its feed the stop ("3719")."""
    return re.sub(r"-a\d+$", "", stop_id) if key == "FT" else stop_id


def route_key(r):
    """How a route is matched from one version of its operator's GTFS to the next (route ids change, names don't);
    src/la-munis.ts reads them the same way."""
    return r["route_short_name"].strip() or r["route_long_name"].strip()


def described(name, line_id, operator):
    """A route's long name as its line's: "10 Whittier Blvd" a "Whittier Blvd", "Route 1", "109" or "DASH A" (saying
    nothing the badge doesn't) the operator's name."""
    name = re.sub(r"^\d+[A-Za-z]?\s+", "", name.strip())
    plain = not name or re.fullmatch(r"(Route|Line)?\s*\d+\w*", name) or name.replace(" ", "") in line_id.replace(" ", "") \
        or line_id.endswith(name) or re.match(r"(DASH|CE\d)", name)
    return operator if plain else name.replace(" - ", " – ")


def read_operator(key, operator, data, line_of):
    archive = zipfile.ZipFile(io.BytesIO(data))
    read = lambda name: csv.DictReader(io.TextIOWrapper(archive.open(name), encoding="utf-8-sig"))
    routes = {r["route_id"]: r for r in read("routes.txt")}
    stops = {s["stop_id"]: s for s in read("stops.txt")}
    trips = {t["trip_id"]: t for t in read("trips.txt")}
    line_ids = {rid: line_of(r) for rid, r in routes.items()}

    sequences = defaultdict(list)
    for row in read("stop_times.txt"):
        sequences[row["trip_id"]].append((int(row["stop_sequence"]), row["stop_id"]))
    runs = {}
    for trip_id, seq in sequences.items():
        trip = trips.get(trip_id)
        if trip and line_ids.get(trip["route_id"]):
            run = tuple(s for _, s in sorted(seq) if s in stops)
            if len(run) > 1:
                runs[trip_id] = run
    sequences.clear()

    # Without direction ids (Montebello's), a trip's way is whether it heads the way the line's longest run does or
    # back; its live trips find theirs by the stop (la.ts).
    at = lambda s: (float(stops[s]["stop_lat"]), float(stops[s]["stop_lon"]))
    heading = lambda run: (at(run[-1])[0] - at(run[0])[0], at(run[-1])[1] - at(run[0])[1])
    longest = {}
    for trip_id, run in runs.items():
        line = line_ids[trips[trip_id]["route_id"]]
        if len(run) > len(longest.get(line, ())):
            longest[line] = run

    def way_of(trip, run):
        if trip.get("direction_id", ""):
            return trip["direction_id"]
        ref, mine = heading(longest[line_ids[trip["route_id"]]]), heading(run)
        return "0" if ref[0] * mine[0] + ref[1] * mine[1] >= 0 else "1"

    patterns = defaultdict(Counter)
    shape_of = {}
    for trip_id, run in runs.items():
        trip = trips[trip_id]
        way = way_of(trip, run)
        k = (line_ids[trip["route_id"]], way)
        patterns[k][run] += 1
        shape_of.setdefault((k, run), trip.get("shape_id", ""))

    shapes = defaultdict(list)
    for row in read("shapes.txt"):
        shapes[row["shape_id"]].append((int(row["shape_pt_sequence"]), float(row["shape_pt_lat"]), float(row["shape_pt_lon"])))

    code = lambda s: f"{key}_{stop_key(key, s)}"
    # Big Blue Bus's stops are in capitals ("PICO BLVD & 17TH ST").
    name_of = lambda s: titled(stops[s]["stop_name"]) if re.sub(r"\(.*?\)", "", stops[s]["stop_name"]).isupper() else stops[s]["stop_name"].strip()
    lines = {}
    for rid, line_id in line_ids.items():
        if not line_id or line_id in lines:
            continue
        route = routes[rid]
        directions = []
        for (lid, way), counted in sorted(patterns.items()):
            if lid != line_id:
                continue
            top = counted.most_common(1)[0][1]
            common = [run for run, n in counted.most_common() if n >= top * COMMON][:6]
            order = chicago.merge_runs([list(r) for r in common])
            end = Counter(run[-1] for run in common).most_common(1)[0][0]
            drawn = []
            for run in common[:3]:
                points = sorted(shapes.get(shape_of[((lid, way), run)], []))
                if len(points) > 1:
                    drawn.append(chicago.simplify([(lat, lon) for _, lat, lon in points]))
            directions.append({
                "id": way,
                "destination": name_of(end),
                "stops": [[code(s), name_of(s), round(float(stops[s]["stop_lat"]), 5), round(float(stops[s]["stop_lon"]), 5)] for s in order],
                "shapes": drawn,
            })
        if not directions:
            continue
        color = route.get("route_color", "").strip()
        text = route.get("route_text_color", "").strip()
        lines[line_id] = {
            "id": line_id,
            "name": described(route["route_long_name"], line_id, operator),
            "mode": "bus",
            "routeId": f"{key}:{line_id}",
            "operator": key,
            "color": f"#{color.upper()}" if color else None,
            "textColor": f"#{text.upper()}" if text else None,
            "directions": directions,
        }
    routes_of = {route_key(r): f"{key}:{line_ids[rid]}" for rid, r in routes.items() if line_ids[rid] in lines}
    return list(lines.values()), routes_of


def main():
    get = lambda url: urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (37 Shades of Late)"}), timeout=120).read()
    if len(sys.argv) == 3:
        rail, bus = (open(path, "rb").read() for path in sys.argv[1:])
    else:
        print("Downloading Metro's GTFS")
        rail, bus = get(FEEDS["rail"]), get(FEEDS["bus"])
    lines = read_feed(rail, True) + read_feed(bus, False)

    # Rail and the busways first, by letter, then buses by number.
    number = lambda l: int(re.match(r"\d*", l["id"])[0] or 10_000)
    lines.sort(key=lambda l: (0, LETTERS.index(l["id"]), 0, "") if l["id"] in LETTERS else (1, 0, number(l), l["id"]))

    # Then the other operators', each's by number.
    operators = {}
    for key, name, gtfs, trip_updates, positions, line_of in OPERATORS:
        print("Reading", name)
        theirs, routes_of = read_operator(key, name, get(gtfs), line_of)
        digits = lambda l: int((re.search(r"\d+", l["id"]) or [10_000])[0])
        lines += sorted(theirs, key=lambda l: (digits(l), l["id"]))
        operators[key] = {"name": name, "gtfs": gtfs, "tripUpdates": trip_updates, "vehiclePositions": positions, "routes": routes_of,
                          "nextStopOnly": key in NEXT_STOP_ONLY}
        print(" ", len(theirs), "lines")
    with open(OUT, "w") as f:
        json.dump({"lines": lines, "operators": operators}, f, separators=(",", ":"))
    print(len(lines), "lines,", os.path.getsize(OUT) // 1024, "KB ->", OUT)


if __name__ == "__main__":
    main()
