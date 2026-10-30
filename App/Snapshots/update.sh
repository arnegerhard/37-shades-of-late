#!/bin/zsh
# Refreshes the line data bundled with the app, so the line map and line list show instantly even
# offline. The app updates these from the proxy at most once a day in the background; run this
# before a release so new installs start current.
set -e
cd "${0:A:h}"
B=https://bus37-proxy.arne-5c1.workers.dev/v1
for city in sf seattle nyc boston; do
  prefix=$([ $city = sf ] && echo "" || echo "$city/")
  curl -sf "$B/${prefix}map?v=2&client=snapshot" -o "linemap-$city.json"
  curl -sf "$B/${prefix}lines?client=snapshot" -o "lines-$city.json"
done
python3 -I - <<'PY'
import json
for city in ("sf", "seattle", "nyc", "boston"):
    m = json.load(open(f"linemap-{city}.json")); l = json.load(open(f"lines-{city}.json"))
    assert m["lines"] and l["lines"], city
    assert m.get("complete", True), f"{city} map incomplete; run again in a minute"
    print(city, len(m["lines"]), "map lines,", len(l["lines"]), "lines")
PY
ls -la *.json
