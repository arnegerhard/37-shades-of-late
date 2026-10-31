#!/bin/zsh
# Captures App Store screenshots on a simulator: ./capture.sh <device-udid> <output-prefix>
# Needs a Debug build of the app installed on that simulator.
set -e
device=$1; prefix=$2
xcrun simctl status_bar $device override --time "$(date +%-H:%M)" --dataNetwork wifi --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
# A fixed set of favorites in every city (see ScreenshotScreen.seedFavoritesIfAsked), so each run looks the same.
xcrun simctl terminate $device info.jetsons.bus37 2>/dev/null || true
xcrun simctl launch $device info.jetsons.bus37 -seedFavorites YES -screen home >/dev/null
sleep 4
i=1
for screen in home lines stops widgets lock; do
  xcrun simctl terminate $device info.jetsons.bus37 2>/dev/null || true
  xcrun simctl launch $device info.jetsons.bus37 -screen $screen >/dev/null
  # Long enough for live data and any opening animation.
  sleep 10
  xcrun simctl io $device screenshot --type=png "${prefix}-$i-$screen.png" >/dev/null 2>&1
  echo "${prefix}-$i-$screen.png"
  i=$((i + 1))
done
# New York, the newest city.
xcrun simctl terminate $device info.jetsons.bus37 2>/dev/null || true
xcrun simctl launch $device info.jetsons.bus37 -seedCity nyc -screen home >/dev/null
sleep 8
xcrun simctl io $device screenshot --type=png "${prefix}-$i-home-nyc.png" >/dev/null 2>&1
echo "${prefix}-$i-home-nyc.png"
