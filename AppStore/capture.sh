#!/bin/zsh
# Captures App Store screenshots on a simulator: ./capture.sh <device-udid> <output-prefix>
# Needs a Debug build of the app installed on that simulator.
set -e
device=$1; prefix=$2
xcrun simctl status_bar $device override --time "$(date +%-H:%M)" --dataNetwork wifi --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
i=1
for screen in home map lines stops widgets lock; do
  xcrun simctl terminate $device info.jetsons.bus37 2>/dev/null || true
  xcrun simctl launch $device info.jetsons.bus37 -screen $screen >/dev/null
  sleep 6
  xcrun simctl io $device screenshot --type=png "${prefix}-$i-$screen.png" >/dev/null 2>&1
  echo "${prefix}-$i-$screen.png"
  i=$((i + 1))
done
