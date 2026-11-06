#!/bin/bash
# Renders banner.html into .github/assets/banner.png, the README header.
# Set CHROME when Chrome is not at the default macOS location.
set -euo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
chrome=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
"$chrome" --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=2 --window-size=1280,640 \
  --screenshot="$dir/../../.github/assets/banner.png" "file://$dir/banner.html"
