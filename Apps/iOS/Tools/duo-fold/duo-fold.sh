#!/bin/bash
# Folds or unfolds an iPhone Duo simulator, for checking layouts in each posture.
#
#   Apps/iOS/Tools/duo-fold/duo-fold.sh <simulator UDID> closed|book|open|<0.0-1.0>
#
# closed is 0°, book about 99° (partially open), open 180°. Start from closed or open: the status
# SpringBoard reports depends on the direction of travel (closing from open stays partially open
# down to about 70°). The app moves between displays live; the cover is screenshot display 1,
# the inner display is display 3:
#
#   xcrun simctl io <udid> screenshot --display=1 cover.png
#   xcrun simctl io <udid> screenshot --display=3 inner.png
#
# Simulator only. The tool uses private SpringBoard SPI (see duo-fold.m) and may break with any
# runtime update. Builds into Apps/iOS/build/ (ignored by git).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
UDID="${1:?usage: duo-fold.sh <simulator UDID> closed|book|open|<0.0-1.0>}"
case "${2:?position}" in
    closed) POSITION=0 ;;
    book) POSITION=0.55 ;;
    open|flat) POSITION=1 ;;
    *) POSITION="$2" ;;
esac
OUT="$HERE/../../build/duo-fold"
mkdir -p "$(dirname "$OUT")"
if [[ ! -x "$OUT" || "$HERE/duo-fold.m" -nt "$OUT" ]]; then
    # The entitlement must be an embedded section; signing it with codesign --entitlements makes
    # the simulator refuse to spawn it.
    xcrun --sdk iphonesimulator clang -target arm64-apple-ios27.1-simulator -fobjc-arc -framework Foundation \
        "$HERE/duo-fold.m" -o "$OUT" -Wl,-sectcreate,__TEXT,__entitlements,"$HERE/entitlements.plist"
fi
xcrun simctl spawn "$UDID" "$OUT" "$POSITION"
