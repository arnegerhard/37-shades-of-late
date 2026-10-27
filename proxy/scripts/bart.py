#!/usr/bin/env python3 -I
"""
Builds proxy/src/bart.json from BART's static GTFS: its six lines (named by color, like BART's maps), each
with a "N" and "S" direction (BART's own route halves, "Yellow-N" and "Yellow-S"), stops in order (platform
ids like "M16-1"), simplified track shapes and colors, plus which line and direction each scheduled trip is.
BART's real-time feed names only the trip, so the proxy needs that map; rerun this when BART publishes a
new schedule:

    python3 -I proxy/scripts/bart.py
"""

import importlib.util, io, json, os, re, urllib.request, zipfile
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("nyc_subway", os.path.join(HERE, "nyc-subway.py"))
nyc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nyc)

GTFS = "https://www.bart.gov/dev/schedules/google_transit.zip"
OUT = os.path.join(HERE, "..", "src", "bart.json")
# The Coliseum–Oakland Airport connector is grey on BART's map, but riders know it by where it goes.
NAMES = {"Grey": "OAK"}


def main():
    # bart.gov turns away Python's default user agent.
    request = urllib.request.Request(GTFS, headers={"User-Agent": "37-shades-of-late (https://37shadesoflate.com)"})
    with urllib.request.urlopen(request) as response:
        z = zipfile.ZipFile(io.BytesIO(response.read()))
    routes = {r["route_id"]: r for r in nyc.read(z, "routes.txt") if r["route_type"] == "1"}
    stops = {s["stop_id"]: s for s in nyc.read(z, "stops.txt")}
    trips = {t["trip_id"]: t for t in nyc.read(z, "trips.txt") if t["route_id"] in routes}

    stop_times = defaultdict(list)
    for st in nyc.read(z, "stop_times.txt"):
        if st["trip_id"] in trips:
            stop_times[st["trip_id"]].append((int(st["stop_sequence"]), st["stop_id"]))
    shapes = defaultdict(list)
    for p in nyc.read(z, "shapes.txt"):
        shapes[p["shape_id"]].append((int(p["shape_pt_sequence"]), float(p["shape_pt_lat"]), float(p["shape_pt_lon"])))

    def key(route):
        color, _, way = route["route_short_name"].partition("-")
        return NAMES.get(color, color), way

    found = defaultdict(lambda: defaultdict(lambda: [0, Counter()]))
    trip_lines = {}
    for trip_id, times in stop_times.items():
        trip = trips[trip_id]
        line, way = key(routes[trip["route_id"]])
        trip_lines[trip_id] = f"{line}|{way}"
        entry = found[(line, way)][tuple(s for _, s in sorted(times))]
        entry[0] += 1
        entry[1][trip["shape_id"]] += 1

    def name(stop_id):
        # "Millbrae (Caltrain Transfer Platform)" → "Millbrae", "Coliseum - OAC" → "Coliseum",
        # "Oakland International Airport Station" → "Oakland International Airport".
        n = re.sub(r"\s*\(.*?\)", "", stops[stop_id]["stop_name"])
        return re.sub(r"( - OAC| Station)$", "", n).strip()

    def stop_info(stop_id):
        s = stops[stop_id]
        return {"code": stop_id, "name": name(stop_id), "lat": round(float(s["stop_lat"]), 6), "lon": round(float(s["stop_lon"]), 6)}

    lines = {}
    for (line, way), patterns in sorted(found.items()):
        ranked = sorted(patterns.items(), key=lambda kv: -kv[1][0])
        order = nyc.merge_patterns([p for p, _ in ranked])
        drawn = []
        for _, (_, shape_ids) in ranked:
            shape = shapes.get(shape_ids.most_common(1)[0][0])
            points = nyc.simplify([[round(lat, 5), round(lon, 5)] for _, lat, lon in sorted(shape)]) if shape else None
            if points and points not in drawn:
                drawn.append(points)
        # The most common last stop is where the line goes, e.g. "Daly City" (some trips turn back early).
        destination = name(Counter(p[-1] for p, _ in ranked for _ in range(patterns[p][0])).most_common(1)[0][0])
        route = next(r for r in routes.values() if key(r) == (line, way))
        entry = lines.setdefault(line, {
            "id": line,
            # Shown after the color in titles ("Yellow BART").
            "name": "BART" if line != "OAK" else "BART to Oakland Airport",
            "mode": "rail",
            "color": "#" + route["route_color"].upper(),
            "textColor": "#" + route["route_text_color"].upper(),
            "directions": [],
        })
        # A station once: trains turning back may use either platform (SFO has two in a row).
        seen, listed = set(), []
        for s in order:
            if name(s) not in seen:
                seen.add(name(s))
                listed.append(stop_info(s))
        entry["directions"].append({"id": way, "name": destination, "destination": destination,
                                    "stops": listed, "shapes": drawn[:3]})

    data = {"source": GTFS, "lines": list(lines.values()), "trips": trip_lines}
    with open(OUT, "w") as f:
        json.dump(data, f, separators=(",", ":"))
    print(f"{len(lines)} lines, {len(trip_lines)} trips, {os.path.getsize(OUT) // 1024} KB -> {os.path.normpath(OUT)}")
    for l in lines.values():
        print(l["id"], [(d["id"], d["destination"], len(d["stops"]), len(d["shapes"])) for d in l["directions"]])


if __name__ == "__main__":
    main()
