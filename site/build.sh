#!/bin/zsh
# Builds public/index.html: one self-contained file with the screenshots inlined as base64.
set -e
cd "${0:A:h}"
# The worker's card renderer (src/card.ts).
[ -d node_modules ] || npm install --no-audit --no-fund
APP_STORE_URL="https://apps.apple.com/app/id6825789256"
API_URL="https://bus37-proxy.arne-5c1.workers.dev"
mkdir -p public
python3 -I - "$APP_STORE_URL" "$API_URL" <<'PY'
import base64, sys
app_store, api = sys.argv[1], sys.argv[2]
html = open("index.src.html").read()
def data_uri(path):
    return "data:image/jpeg;base64," + base64.b64encode(open(path, "rb").read()).decode()
for key, value in {
    "{{APP_STORE_URL}}": app_store,
    "{{API_URL}}": api,
    "{{PRIVACY_URL}}": "/privacy",
    "{{SUPPORT_URL}}": "/support",
    "{{IMG_HOME}}": data_uri("images/home.jpg"),
    "{{IMG_LOCKWIDGET}}": data_uri("images/lockwidget.jpg"),
    "{{IMG_PICKER}}": data_uri("images/picker.jpg"),
    # The map of the cities (scripts/cities.mjs draws it).
    "{{CITIES_SVG}}": open("images/cities.svg").read(),
}.items():
    html = html.replace(key, value)
assert "{{" not in html, "unfilled placeholder"
open("public/index.html", "w").write(html)
print(f"public/index.html: {len(html) // 1024} KB")
PY
# Privacy, support and the shared-stop page (/s) are plain static files.
cp pages/privacy.html pages/support.html pages/s.html public/
# The homepage's link preview (scripts/preview.mjs draws it).
cp images/preview.png public/
# Lets 37shadesoflate.com/s links open the app when it's installed (universal links). Apple reads it
# as JSON, which the _headers file makes sure of.
mkdir -p public/.well-known
cat > public/.well-known/apple-app-site-association <<'JSON'
{"applinks": {"details": [{"appIDs": ["DLJLEZ2Y6W.info.jetsons.bus37"], "components": [{"/": "/s", "comment": "a shared stop"}]}]}}
JSON
cat > public/_headers <<'TXT'
/.well-known/apple-app-site-association
  Content-Type: application/json
TXT
