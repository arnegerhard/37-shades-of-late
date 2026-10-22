#!/bin/zsh
# Prints usage statistics from the 37ShadesOfLate Analytics Engine dataset.
# Needs a Cloudflare API token with Account Analytics: Read in proxy/.analytics-token.
# Usage: proxy/stats.sh [days]   (default 7)
set -e
days=${1:-7}
token_file="${0:A:h}/.analytics-token"
account=5c16a3f67b5851cf42828b7c52ee53e6
# Leaves out test events (app version "test") and anything from Debug simulator builds can't be
# told apart, so ignore data from before the App Store release.
where="timestamp > NOW() - INTERVAL '$days' DAY AND blob7 != 'test'"

query() {
  echo "\n== $1"
  curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/$account/analytics_engine/sql" \
    -H "Authorization: Bearer $(tr -d '[:space:]' < $token_file)" \
    --data "$2 FORMAT JSON" | python3 -I -c '
import json, sys
raw = sys.stdin.read()
try:
    rows = json.loads(raw)["data"]
except Exception:
    sys.exit("  error: " + raw.strip()[:300])
if not rows:
    sys.exit("  (no data)")
cols = list(rows[0])
widths = [max(len(c), *(len(str(r[c])) for r in rows)) for c in cols]
for line in [cols] + [[str(r[c]) for c in cols] for r in rows]:
    print("  " + "  ".join(v.ljust(w) for v, w in zip(line, widths)))
'
}

query "Installs and requests per day" \
  "SELECT toDate(timestamp) AS day, count(DISTINCT blob6) AS installs, SUM(_sample_interval) AS requests
   FROM \"37ShadesOfLate\" WHERE $where GROUP BY day ORDER BY day"
query "By city" \
  "SELECT if(blob8 = '', 'sf', blob8) AS city, count(DISTINCT blob6) AS installs, SUM(_sample_interval) AS requests
   FROM \"37ShadesOfLate\" WHERE $where GROUP BY city ORDER BY requests DESC"
query "App vs. widget vs. map" \
  "SELECT blob2 AS client, count(DISTINCT blob6) AS installs, SUM(_sample_interval) AS requests
   FROM \"37ShadesOfLate\" WHERE $where GROUP BY client ORDER BY requests DESC"
query "Active days per install" \
  "SELECT active_days, count() AS installs FROM (
     SELECT blob6, count(DISTINCT toDate(timestamp)) AS active_days
     FROM \"37ShadesOfLate\" WHERE $where GROUP BY blob6)
   GROUP BY active_days ORDER BY active_days"
query "Top lines and stops" \
  "SELECT if(blob8 = '', 'sf', blob8) AS city, blob3 AS line, blob4 AS stop, blob5 AS direction, count(DISTINCT blob6) AS installs,
          SUM(_sample_interval) AS requests
   FROM \"37ShadesOfLate\" WHERE $where AND blob1 = 'departures'
   GROUP BY city, line, stop, direction ORDER BY installs DESC, requests DESC LIMIT 15"
query "Requests by hour of day (UTC)" \
  "SELECT toHour(timestamp) AS hour, SUM(_sample_interval) AS requests
   FROM \"37ShadesOfLate\" WHERE $where GROUP BY hour ORDER BY hour"
query "Favorites per install" \
  "SELECT favorites, count() AS installs FROM (
     SELECT blob6, max(double1) AS favorites FROM \"37ShadesOfLate\" WHERE $where GROUP BY blob6)
   GROUP BY favorites ORDER BY favorites"
