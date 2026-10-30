#!/usr/bin/env python3 -I
"""
Builds proxy/src/la.json from LA Metro's static GTFS, rail and bus (both public on GitLab): every line with its
stops in order per direction (the common patterns merged), where each way ends up, simplified shapes and colors,
as chicago.py does for Chicago. The bus schedule alone is 300 MB unpacked, and the network changes a few times a
year, so this runs by hand:

    python3 -I proxy/scripts/la.py

or from feeds already downloaded: python3 -I proxy/scripts/la.py rail.zip bus.zip

Live departures come from Metro's GTFS-realtime feeds, through Swiftly, at request time (see src/la.ts).
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


def main():
    if len(sys.argv) == 3:
        rail, bus = (open(path, "rb").read() for path in sys.argv[1:])
    else:
        print("Downloading Metro's GTFS")
        get = lambda url: urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "37 Shades of Late"})).read()
        rail, bus = get(FEEDS["rail"]), get(FEEDS["bus"])
    lines = read_feed(rail, True) + read_feed(bus, False)

    # Rail and the busways first, by letter, then buses by number.
    number = lambda l: int(re.match(r"\d*", l["id"])[0] or 10_000)
    lines.sort(key=lambda l: (0, LETTERS.index(l["id"]), 0, "") if l["id"] in LETTERS else (1, 0, number(l), l["id"]))
    with open(OUT, "w") as f:
        json.dump({"lines": lines}, f, separators=(",", ":"))
    print(len(lines), "lines,", os.path.getsize(OUT) // 1024, "KB ->", OUT)


if __name__ == "__main__":
    main()
