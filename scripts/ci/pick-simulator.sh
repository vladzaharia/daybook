#!/bin/bash
# Prints the UDID of the iPhone simulator to test on, and describes the choice on stderr.
#
#   scripts/ci/pick-simulator.sh [--prefer "iPhone Duo"] [--prefer "iPhone 18 Pro"]...
#
# Takes the first preferred device type that exists, on the newest iOS runtime that has it; with no
# match, the first iPhone on the newest runtime. The default preference is iPhone Duo (the app's
# primary device; it needs the iOS 27.1 runtime), then iPhone 18 Pro.
#
# On the `xcode-27` runner image (20261012) there's no iPhone Duo: the iOS 27.1 runtime isn't
# preinstalled, and Apple's iOS 27.1 runtime supports only the iPhone Duo device type, while the
# iOS 27.0 runtime has every other iPhone (actions/runner-images#15000). So CI gets iPhone 18 Pro on
# iOS 27.0, built with the iOS 27.1 SDK, where the `#available(iOS 27.1, *)` hinge code is compiled
# but not run. Once an image ships an iPhone Duo device, this picks it up with no change.
set -euo pipefail

prefs=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefer) prefs+=("${2-}"); shift ;;
        *) echo "pick-simulator.sh: unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
(( ${#prefs[@]} )) || prefs=("iPhone Duo" "iPhone 18 Pro")

devices="$(xcrun simctl list -j devices available)"
# Every available iOS device as "rank<TAB>name<TAB>udid<TAB>runtime", newest runtime first; the rank is
# major * 1000 + minor, and the sort is stable, so simctl's order holds within a runtime.
listing="$(printf '%s' "$devices" | jq -r '
    .devices | to_entries[]
    | select(.key | test("SimRuntime\\.iOS-"))
    | (.key | capture("iOS-(?<major>[0-9]+)-(?<minor>[0-9]+)")) as $v
    | .value[] | select(.isAvailable != false)
    | "\(($v.major | tonumber) * 1000 + ($v.minor | tonumber))\t\(.name)\t\(.udid)\tiOS \($v.major).\($v.minor)"' \
    | sort -s -t $'\t' -k1,1nr)"

choose() {
    printf '%s\n' "$listing" | awk -F'\t' -v name="$1" '$2 == name { print $3 "\t" $2 "\t" $4; exit }'
}

pick=""
for name in "${prefs[@]}"; do
    pick="$(choose "$name")"
    [[ -n "$pick" ]] && break
    echo "pick-simulator.sh: no $name simulator here" >&2
done
if [[ -z "$pick" ]]; then
    pick="$(printf '%s\n' "$listing" | awk -F'\t' '$2 ~ /^iPhone/ { print $3 "\t" $2 "\t" $4; exit }')"
fi
[[ -n "$pick" ]] || { echo "pick-simulator.sh: no iPhone simulator is available" >&2; exit 1; }

udid="$(printf '%s' "$pick" | cut -f1)"
echo "pick-simulator.sh: testing on $(printf '%s' "$pick" | cut -f2) ($(printf '%s' "$pick" | cut -f3)), $udid" >&2
echo "$udid"
