#!/bin/bash
# Fails when a build log has a warning in Daybook's own code: a file under Sources/ or Apps/iOS/, not a
# dependency's (.build/checkouts, Xcode's SourcePackages) or the package's tests (Tests/). It reads paths, not counts,
# so what a runner prints around the diagnostics doesn't matter. Only the files a build compiles report, so a warning
# shows when its file, or one it depends on, changes.
#
#   scripts/ci/own-warnings.sh <build log>
set -euo pipefail

log="${1:?usage: own-warnings.sh <build log>}"
[[ -r "$log" ]] || { echo "own-warnings.sh: can't read $log" >&2; exit 2; }

# Colour codes out, then each diagnostic's own line (the one that starts with its path), once.
warnings="$(sed -e $'s/\x1b\\[[0-9;]*m//g' "$log" \
    | grep -E '(^|/)(Sources|Apps/iOS)/[^:]+:[0-9]+:([0-9]+:)? warning:' \
    | grep -vE '/(\.build|SourcePackages|DerivedData)/' \
    | sort -u || true)"

if [[ -n "$warnings" ]]; then
    count="$(printf '%s\n' "$warnings" | wc -l | tr -d ' ')"
    echo "::error title=Warnings in Daybook's own code::$count in Sources/ or Apps/iOS/; the dependencies' don't count"
    printf '%s\n' "$warnings"
    exit 1
fi
echo "No warnings in Sources/ or Apps/iOS/."
