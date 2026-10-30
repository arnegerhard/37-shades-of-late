#!/usr/bin/env python3 -I
"""
Builds proxy/src/chicago.json from the CTA's static GTFS: every 'L' line and bus route with its stops in order
per direction (the common patterns merged), where each way ends up, simplified shapes and colors. The CTA's
stop times (about 370 MB) are far too big to read in the Worker, and the network changes a few times a year,
so this runs by hand when the CTA publishes a new schedule:

    python3 -I proxy/scripts/chicago.py

Live departures come from the CTA's GTFS-realtime feeds at request time (see src/chicago.ts).
"""

import csv, io, json, math, os, urllib.request, zipfile
from collections import Counter, defaultdict

GTFS = "https://www.transitchicago.com/downloads/sch_data/google_transit.zip"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "chicago.json")

# The 'L' lines as riders say them; the GTFS has "Brn", "G", "Org", "P" and "Y".
RAIL = {"Red": "Red", "Blue": "Blue", "Brn": "Brown", "G": "Green", "Org": "Orange", "P": "Purple", "Pink": "Pink", "Y": "Yellow"}
# Patterns run by fewer trips than this share of the busiest one's are detours and specials.
COMMON = 0.1


def simplify(points, tolerance=12):
    """Douglas-Peucker in meters, as src/geo.ts's simplify. A loop (the Brown Line's, out around the Loop and
    back to where it started) is done in two halves, split where it's farthest from its start: with both
    ends in one place there'd be no line to measure from."""
    if len(points) > 3 and math.hypot(points[0][0] - points[-1][0], points[0][1] - points[-1][1]) < 0.002:
        far = max(range(len(points)), key=lambda i: math.hypot(points[i][0] - points[0][0], points[i][1] - points[0][1]))
        return simplify(points[:far + 1], tolerance) + simplify(points[far:], tolerance)[1:]
    if len(points) < 3:
        return [[round(a, 5), round(b, 5)] for a, b in points]
    lat0 = points[0][0]
    xy = [(p[1] * 111_320 * math.cos(math.radians(lat0)), p[0] * 110_540) for p in points]
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        a, b = stack.pop()
        (ax, ay), (bx, by) = xy[a], xy[b]
        length = math.hypot(bx - ax, by - ay) or 1e-9
        best, index = 0, -1
        for i in range(a + 1, b):
            px, py = xy[i]
            d = abs((bx - ax) * (ay - py) - (ax - px) * (by - ay)) / length
            if d > best:
                best, index = d, i
        if best > tolerance:
            keep[index] = True
            stack += [(a, index), (index, b)]
    return [[round(p[0], 5), round(p[1], 5)] for p, k in zip(points, keep) if k]


def merge_runs(runs):
    """The longest run, with stops only other runs have placed after the one before them."""
    runs = sorted(runs, key=len, reverse=True)
    merged = list(runs[0])
    for run in runs[1:]:
        for i, stop in enumerate(run):
            if stop in merged:
                continue
            before = merged.index(run[i - 1]) if i > 0 and run[i - 1] in merged else -1
            merged.insert(before + 1, stop)
    return merged


def main():
    print("Downloading", GTFS)
    data = urllib.request.urlopen(urllib.request.Request(GTFS, headers={"User-Agent": "37 Shades of Late"})).read()
    archive = zipfile.ZipFile(io.BytesIO(data))
    read = lambda name: csv.DictReader(io.TextIOWrapper(archive.open(name), encoding="utf-8-sig"))

    routes = list(read("routes.txt"))
    stops = {s["stop_id"]: s for s in read("stops.txt")}
    trips = {t["trip_id"]: t for t in read("trips.txt")}

    print("Reading stop times")
    sequences = defaultdict(list)
    for row in read("stop_times.txt"):
        sequences[row["trip_id"]].append((int(row["stop_sequence"]), row["stop_id"]))

    # How many trips run each stop pattern, per route and direction, and a shape for each.
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
        rail = route["route_type"] == "1"
        directions = []
        for direction in ("0", "1"):
            counted = patterns.get((rid, direction))
            if not counted:
                continue
            top = counted.most_common(1)[0][1]
            common = [run for run, n in counted.most_common() if n >= top * COMMON][:6]
            order = merge_runs([list(r) for r in common])
            ends = Counter(run[-1] for run in common)
            end = stops[ends.most_common(1)[0][0]]
            destination = stops.get(end.get("parent_station") or "", end)["stop_name"] if rail else end["stop_name"]
            drawn = []
            for run in common[:3]:
                points = sorted(shapes.get(shape_of[((rid, direction), run)], []))
                if len(points) > 1:
                    drawn.append(simplify([(lat, lon) for _, lat, lon in points]))
            directions.append({
                "id": direction,
                "destination": destination,
                # Rail platforms by their station's name, as riders say them.
                "stops": [[s, (stops.get(stops[s].get("parent_station") or "", stops[s]) if rail else stops[s])["stop_name"],
                           round(float(stops[s]["stop_lat"]), 5), round(float(stops[s]["stop_lon"]), 5)] for s in order if s in stops],
                "shapes": drawn,
            })
        if not directions:
            continue
        line_id = RAIL.get(rid, route["route_short_name"] or rid)
        # The Brown, Orange, Pink and Purple Lines (and the Yellow's shuttle) run out and back as one
        # trip, around the Loop and home: one GTFS direction. Riders know two, so split it where the
        # train is farthest from where it started, going toward the Loop (or Dempster-Skokie) and back.
        if rail and len(directions) == 1:
            way = directions[0]
            first = way["stops"][0]
            far = max(range(len(way["stops"])), key=lambda i: math.hypot(way["stops"][i][2] - first[2], (way["stops"][i][3] - first[3]) * 0.74))
            out, back = way["stops"][:far + 1], way["stops"][far:]
            toward = "Loop" if line_id in ("Brown", "Orange", "Pink", "Purple") else out[-1][1]
            directions = [
                {"id": "out", "destination": toward, "stops": out, "shapes": way["shapes"]},
                {"id": "back", "destination": way["destination"], "stops": back, "shapes": []},
            ]
        lines.append({
            "id": line_id,
            "name": f"{line_id} Line" if rail else route["route_long_name"],
            "mode": "subway" if rail else "bus",
            "routeId": rid,
            "color": f"#{route['route_color'].upper()}" if route["route_color"] else None,
            "textColor": f"#{route['route_text_color'].upper()}" if route["route_text_color"] else None,
            "directions": directions,
        })

    # The 'L' first, in the CTA's order, then buses by number.
    order = list(RAIL.values())
    key = lambda l: (0, order.index(l["id"])) if l["id"] in order else (1, int("".join(c for c in l["id"] if c.isdigit()) or 0), l["id"])
    lines.sort(key=key)
    with open(OUT, "w") as f:
        json.dump({"lines": lines}, f, separators=(",", ":"))
    print(len(lines), "lines,", os.path.getsize(OUT) // 1024, "KB ->", OUT)


if __name__ == "__main__":
    main()
