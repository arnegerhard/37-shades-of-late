#!/usr/bin/env python3 -I
"""
Builds proxy/src/nyc-subway.json from the MTA's static subway GTFS and PATH's: every line with its stops in
order per direction (branches merged in), the most common destination each way, simplified track shapes,
colors, and which subway stations are transfers. The subway's stop times are far too big to read in the Worker on each refresh,
and the network changes rarely, so this runs by hand when the MTA publishes a new schedule:

    python3 -I proxy/scripts/nyc-subway.py

Live departures come from the MTA's real-time feeds at request time (see src/nyc.ts).
"""

import csv, io, json, math, os, urllib.request, zipfile
from collections import Counter, defaultdict

GTFS = "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip"
PATH_GTFS = "http://data.trilliumtransit.com/gtfs/path-nj-us/path-nj-us.zip"

# PATH, named like its signs and the RidePATH feed: station codes and the regular lines (the rare Harrison
# shuttle and WTC–33rd runs are left out). Each line has a "Y" direction (to New York) and a "J" one (to
# New Jersey), which is also the last letter of its stop codes ("PJSQY"), so PATH platforms never pair up
# with the subway's N and S ones.
PATH_STATIONS = {
    "Newark": "NWK", "Harrison": "HAR", "Journal Square": "JSQ", "Grove Street": "GRV", "Newport": "NEW",
    "Exchange Place": "EXP", "Hoboken": "HOB", "World Trade Center": "WTC", "Christopher Street": "CHR",
    "9th Street": "09S", "14th Street": "14S", "23rd Street": "23S", "33rd Street": "33S",
}
PATH_LINES = {"862": "NWK–WTC", "861": "JSQ–33", "859": "HOB–33", "860": "HOB–WTC", "1024": "JSQ–33 via HOB"}
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "nyc-subway.json")

# Express runs (the diamond 6, 7 and F) are the same line to a rider; they just skip stops.
MERGE = {"6X": "6", "7X": "7", "FX": "F"}
# The three shuttles are all "S" on the signs; tell them apart.
NAMES = {"GS": "S 42 St", "FS": "S Franklin", "H": "S Rockaway", "SI": "SIR"}
# Which real-time feed carries each line.
FEEDS = {
    **{r: "gtfs" for r in ["1", "2", "3", "4", "5", "6", "7", "GS"]},
    **{r: "gtfs-ace" for r in ["A", "C", "E", "FS", "H"]},
    **{r: "gtfs-bdfm" for r in ["B", "D", "F", "M"]},
    "G": "gtfs-g", "J": "gtfs-jz", "Z": "gtfs-jz", "L": "gtfs-l",
    **{r: "gtfs-nqrw" for r in ["N", "Q", "R", "W"]},
    "SI": "gtfs-si",
}


def read(z, name):
    return list(csv.DictReader(io.TextIOWrapper(z.open(name), encoding="utf-8-sig")))


def simplify(points, tolerance=12.0):
    """Douglas–Peucker in meters, like geo.ts's simplify."""
    if len(points) < 3:
        return points
    lat0 = points[0][0]
    xy = [(p[1] * 111_320 * math.cos(math.radians(lat0)), p[0] * 110_540) for p in points]
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        a, b = stack.pop()
        (ax, ay), (bx, by) = xy[a], xy[b]
        dx, dy = bx - ax, by - ay
        length = math.hypot(dx, dy) or 1
        far, dist = -1, tolerance
        for i in range(a + 1, b):
            px, py = xy[i]
            d = abs(dy * px - dx * py + bx * ay - by * ax) / length
            if d > dist:
                far, dist = i, d
        if far >= 0:
            keep[far] = True
            stack += [(a, far), (far, b)]
    return [p for p, k in zip(points, keep) if k]


def merge_patterns(patterns):
    """One stop order holding every stop of every pattern: the most common pattern, with the stops
    only other patterns have (branches, short turns) slotted in after the stop before them."""
    order = list(patterns[0])
    for pattern in patterns[1:]:
        for i, stop in enumerate(pattern):
            if stop in order:
                continue
            before = next((pattern[j] for j in range(i - 1, -1, -1) if pattern[j] in order), None)
            order.insert(order.index(before) + 1 if before else 0, stop)
    return order


def path_lines():
    """PATH's lines, in the same shape as the subway's."""
    with urllib.request.urlopen(PATH_GTFS) as response:
        z = zipfile.ZipFile(io.BytesIO(response.read()))
    routes = {r["route_id"]: r for r in read(z, "routes.txt")}
    stops = {s["stop_id"]: s for s in read(z, "stops.txt")}
    trips = {t["trip_id"]: t for t in read(z, "trips.txt") if t["route_id"] in PATH_LINES}

    def station(stop_id):
        s = stops[stop_id]
        return stops.get(s["parent_station"], s) if s["parent_station"] else s

    stop_times = defaultdict(list)
    for st in read(z, "stop_times.txt"):
        if st["trip_id"] in trips:
            stop_times[st["trip_id"]].append((int(st["stop_sequence"]), st["stop_id"]))
    shapes = defaultdict(list)
    for p in read(z, "shapes.txt"):
        shapes[p["shape_id"]].append((int(p["shape_pt_sequence"]), float(p["shape_pt_lat"]), float(p["shape_pt_lon"])))

    found = defaultdict(lambda: defaultdict(lambda: defaultdict(lambda: [0, Counter()])))
    for trip_id, times in stop_times.items():
        trip = trips[trip_id]
        way = "Y" if trip["direction_id"] == "1" else "J"
        pattern = tuple(PATH_STATIONS[station(s)["stop_name"]] for _, s in sorted(times))
        entry = found[trip["route_id"]][way][pattern]
        entry[0] += 1
        entry[1][trip["shape_id"]] += 1

    by_code = {code: station_info for code, station_info in (
        (PATH_STATIONS[s["stop_name"]], s) for s in stops.values() if s["location_type"] == "1")}
    lines = []
    for route_id, name in PATH_LINES.items():
        directions = []
        for way in ("Y", "J"):
            ranked = sorted(found[route_id][way].items(), key=lambda kv: -kv[1][0])
            if not ranked:
                continue
            order = merge_patterns([p for p, _ in ranked])
            shape = shapes.get(ranked[0][1][1].most_common(1)[0][0])
            destination = by_code[order[-1]]["stop_name"]
            directions.append({
                "id": way,
                "name": destination,
                "destination": destination,
                "stops": [{"code": f"P{code}{way}", "name": by_code[code]["stop_name"],
                           "lat": round(float(by_code[code]["stop_lat"]), 6),
                           "lon": round(float(by_code[code]["stop_lon"]), 6)} for code in order],
                "shapes": [simplify([[round(lat, 5), round(lon, 5)] for _, lat, lon in sorted(shape)])] if shape else [],
            })
        route = routes[route_id]
        lines.append({
            "id": name,
            "routeId": f"PATH-{route_id}",
            "name": f"PATH {route['route_long_name']}",
            "mode": "rail",
            "color": "#" + route["route_color"].upper(),
            "textColor": "#" + route["route_text_color"].upper(),
            "feed": "path",
            "directions": directions,
        })
    return lines


def main():
    with urllib.request.urlopen(GTFS) as response:
        z = zipfile.ZipFile(io.BytesIO(response.read()))
    routes = {r["route_id"]: r for r in read(z, "routes.txt")}
    stops = {s["stop_id"]: s for s in read(z, "stops.txt")}
    trips = {t["trip_id"]: t for t in read(z, "trips.txt")}

    stop_times = defaultdict(list)
    for st in read(z, "stop_times.txt"):
        stop_times[st["trip_id"]].append((int(st["stop_sequence"]), st["stop_id"]))

    shapes = defaultdict(list)
    for p in read(z, "shapes.txt"):
        shapes[p["shape_id"]].append((int(p["shape_pt_sequence"]), float(p["shape_pt_lat"]), float(p["shape_pt_lon"])))

    # line -> direction ("N"/"S") -> pattern (tuple of stop ids) -> [count, shape ids, headsigns]
    found = defaultdict(lambda: defaultdict(lambda: defaultdict(lambda: [0, Counter(), Counter()])))
    for trip_id, times in stop_times.items():
        trip = trips[trip_id]
        line = MERGE.get(trip["route_id"], trip["route_id"])
        pattern = tuple(s for _, s in sorted(times))
        direction = pattern[0][-1]
        if direction not in "NS":
            continue
        entry = found[line][direction][pattern]
        entry[0] += 1
        if trip["shape_id"]:
            entry[1][trip["shape_id"]] += 1
        entry[2][trip["trip_headsign"]] += 1

    def stop_info(stop_id):
        s = stops[stop_id]
        return {"code": stop_id, "name": s["stop_name"], "lat": round(float(s["stop_lat"]), 6), "lon": round(float(s["stop_lon"]), 6)}

    lines = []
    for route_id, route in routes.items():
        if route_id in MERGE:
            continue
        directions = []
        for direction in ("N", "S"):
            patterns = found[route_id].get(direction)
            if not patterns:
                continue
            ranked = sorted(patterns.items(), key=lambda kv: -kv[1][0])
            order = merge_patterns([p for p, _ in ranked])
            headsigns = sum((v[2] for _, v in ranked), Counter())
            # The shapes of the patterns that bring new stops, so every branch is drawn once.
            drawn, covered = [], set()
            for pattern, (_, shape_ids, _) in ranked:
                if set(pattern) <= covered or not shape_ids:
                    continue
                covered |= set(pattern)
                shape = shapes.get(shape_ids.most_common(1)[0][0])
                if shape:
                    points = simplify([[round(lat, 5), round(lon, 5)] for _, lat, lon in sorted(shape)])
                    # Different shape ids often trace the same track.
                    if points not in drawn:
                        drawn.append(points)
            destination = headsigns.most_common(1)[0][0]
            directions.append({
                "id": direction,
                "name": destination,
                "destination": destination,
                "stops": [stop_info(s) for s in order],
                "shapes": drawn,
            })
        if not directions:
            continue
        lines.append({
            "id": NAMES.get(route_id, route_id),
            "routeId": route_id,
            "name": route["route_long_name"],
            "mode": "subway" if route["route_type"] == "1" else "rail",
            "color": "#" + route["route_color"].upper() if route["route_color"] else None,
            "textColor": "#" + route["route_text_color"].upper() if route["route_text_color"] else None,
            "feed": FEEDS[route_id],
            "directions": directions,
        })

    # Stations you can change at without leaving the system, by parent station id.
    transfers = defaultdict(set)
    for t in read(z, "transfers.txt"):
        if t["from_stop_id"] != t["to_stop_id"]:
            transfers[t["from_stop_id"]].add(t["to_stop_id"])

    # Numbers, then letters, then the shuttles and the Staten Island Railway, then PATH.
    lines.sort(key=lambda l: (l["mode"] != "subway", l["id"].startswith("S "), len(l["id"]) > 1, l["id"]))
    lines += path_lines()
    data = {
        "source": [GTFS, PATH_GTFS],
        "lines": lines,
        "transfers": {k: sorted(v) for k, v in sorted(transfers.items())},
    }
    with open(OUT, "w") as f:
        json.dump(data, f, separators=(",", ":"))
    print(f"{len(lines)} lines, {os.path.getsize(OUT) // 1024} KB -> {os.path.normpath(OUT)}")
    for l in lines:
        print(l["id"], [(d["id"], d["destination"], len(d["stops"]), len(d["shapes"])) for d in l["directions"]])


if __name__ == "__main__":
    main()
