#!/bin/bash
# Runs the Swift package's test bundles in lanes side by side: each lane's bundles one after another, and every bundle
# whatever the others did. CI's package job (docs/release.md, CI): the runner has three cores, and the tests mostly
# keep one busy.
#
#   scripts/ci/test-lanes.sh --expect "TARGET..." --products DIR --logs DIR [--skip BUNDLE PATTERN]... LANE...
#
# LANE        test bundles (test target names), separated by spaces: "DaybookCoreTests DaybookKitTests"
# --expect    the package's test targets (`swift package dump-package`): each must be in exactly one lane, and a lane
#             holds nothing else, so a new test target can't go unrun and a removed one's bundle, which a build leaves
#             behind in the products folder, isn't run
# --products  where the built .xctest bundles are (`swift build --show-bin-path`)
# --logs      a folder for each bundle's log (BUNDLE.log)
# --skip      leaves out BUNDLE's tests that match PATTERN (`swift test --skip`); BUNDLE must be in a lane. It runs through
#             `swift test --skip-build --ignore-lock`; every other one straight from its bundle with xctest, which spares
#             SwiftPM's start, about 15 s a bundle on a runner.
#
# Afterwards prints each bundle's log in a group, an error annotation for each that failed (naming its failed tests),
# and a table of the results, to $GITHUB_STEP_SUMMARY too when it's set. Exits 1 if any bundle failed.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

expect=""
products=""
logs=""
skip_bundles=()
skip_patterns=()
lanes=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --expect) expect="${2-}"; shift ;;
        --products) products="${2-}"; shift ;;
        --logs) logs="${2-}"; shift ;;
        --skip) skip_bundles+=("${2-}"); skip_patterns+=("${3-}"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "test-lanes.sh: unknown option: $1" >&2; exit 2 ;;
        *) lanes+=("$1") ;;
    esac
    shift
done
[[ -n "$products" && -n "$logs" ]] || { echo "test-lanes.sh: --products and --logs are required" >&2; exit 2; }
[[ -n "${expect// /}" ]] || { echo "test-lanes.sh: --expect needs the package's test targets" >&2; exit 2; }
(( ${#lanes[@]} )) || { echo "test-lanes.sh: no lanes" >&2; exit 2; }
[[ -d "$products" ]] || { echo "test-lanes.sh: no products folder at $products" >&2; exit 2; }

assigned=" "
for lane in "${lanes[@]}"; do
    for bundle in $lane; do
        [[ "$bundle" =~ ^[A-Za-z0-9_]+$ ]] || { echo "test-lanes.sh: not a test bundle name: $bundle" >&2; exit 2; }
        [[ "$assigned" != *" $bundle "* ]] || { echo "test-lanes.sh: $bundle is in two lanes" >&2; exit 2; }
        assigned+="$bundle "
    done
done
unassigned=""
for bundle in $expect; do
    [[ "$assigned" == *" $bundle "* ]] || unassigned+=" $bundle"
done
if [[ -n "$unassigned" ]]; then
    echo "::error title=Test target in no lane::$unassigned: add each to a lane in .github/workflows/ci.yml"
    exit 2
fi
for bundle in $assigned; do
    if [[ " $expect " != *" $bundle "* ]]; then
        echo "::error title=Not a test target::$bundle is in a lane but the package has no such test target"
        exit 2
    fi
    [[ -d "$products/$bundle.xctest" ]] || { echo "test-lanes.sh: $bundle wasn't built (no $products/$bundle.xctest)" >&2; exit 2; }
done
for bundle in ${skip_bundles[@]+"${skip_bundles[@]}"}; do
    [[ "$assigned" == *" $bundle "* ]] || { echo "test-lanes.sh: --skip names $bundle, which is in no lane" >&2; exit 2; }
done

mkdir -p "$logs"
rm -f "$logs"/*.result

# run_bundle BUNDLE: runs it, writing its log, then "STATUS SECONDS" to BUNDLE.result.
run_bundle() {
    local bundle="$1" start=$SECONDS status=0 i
    local skips=()
    for (( i = 0; i < ${#skip_bundles[@]}; i++ )); do
        if [[ "${skip_bundles[$i]}" == "$bundle" ]]; then skips+=(--skip "${skip_patterns[$i]}"); fi
    done
    if (( ${#skips[@]} )); then
        swift test --skip-build --ignore-lock --filter "^$bundle\\." "${skips[@]}" > "$logs/$bundle.log" 2>&1 || status=$?
    else
        xcrun xctest "$products/$bundle.xctest" > "$logs/$bundle.log" 2>&1 || status=$?
    fi
    printf '%s %s\n' "$status" "$(( SECONDS - start ))" > "$logs/$bundle.result"
}

start=$SECONDS
pids=()
for lane in "${lanes[@]}"; do
    ( for bundle in $lane; do run_bundle "$bundle"; done ) &
    pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid" || true; done
elapsed=$(( SECONDS - start ))

failed=0
rows=""
for (( n = 0; n < ${#lanes[@]}; n++ )); do
    for bundle in ${lanes[$n]}; do
        status=1 seconds=0
        if [[ -f "$logs/$bundle.result" ]]; then read -r status seconds < "$logs/$bundle.result"; fi
        if [[ "$status" == 0 ]]; then result=passed; else result="failed (exit $status)"; failed=1; fi
        echo "::group::$bundle: $result in $seconds s (lane $(( n + 1 )))"
        cat "$logs/$bundle.log" 2>/dev/null || true
        echo "::endgroup::"
        if [[ "$status" != 0 ]]; then
            tests="$(grep -oE "Test Case '-\[[^]]+\]' failed" "$logs/$bundle.log" 2>/dev/null \
                | sed -E "s/^Test Case '-\[([^ ]+) ([^]]+)\]' failed$/\1.\2/" | sort -u | paste -sd ',' - || true)"
            echo "::error title=Tests failed::$bundle: ${tests:-exit $status, no failed test named (a crash?); see its log group}"
        fi
        rows+="| $bundle | $(( n + 1 )) | $result | $seconds s |"$'\n'
    done
done
table="$(printf '| Bundle | Lane | Result | Time |\n|---|---|---|---|\n%s' "$rows")"
echo "${#lanes[@]} lanes in $elapsed s"
printf '%s\n' "$table"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '### Package tests, %s lanes in %s s\n%s\n' "${#lanes[@]}" "$elapsed" "$table" >> "$GITHUB_STEP_SUMMARY"
fi
exit "$failed"
