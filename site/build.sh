#!/bin/zsh
# Builds public/index.html: one self-contained file with the screenshots inlined as base64.
set -e
cd "${0:A:h}"
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
    "{{IMG_MAP}}": data_uri("images/map.jpg"),
}.items():
    html = html.replace(key, value)
assert "{{" not in html, "unfilled placeholder"
open("public/index.html", "w").write(html)
print(f"public/index.html: {len(html) // 1024} KB")
PY
# Privacy and support pages are plain static files.
cp pages/privacy.html pages/support.html public/
