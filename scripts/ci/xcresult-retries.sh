#!/bin/bash
# Reports the tests in an Xcode result bundle whose attempts disagreed: passed on a retry
# (-retry-tests-on-failure) or flaky across -test-iterations. xcodebuild calls a pass on retry a pass,
# so without this the run is green and nobody sees the failure; each such test gets a warning
# annotation, as scripts/ci/retry.sh gives the package's timing test.
#
#   scripts/ci/xcresult-retries.sh <bundle.xcresult>
#   scripts/ci/xcresult-retries.sh --json <tests.json>     (xcresulttool's output, for tests)
#
# Prints one ::warning per such test, and adds them to $GITHUB_STEP_SUMMARY when it's set. Always exits
# 0 unless its input can't be read: a test that failed every attempt has already failed xcodebuild.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

case "${1-}" in
    --json)
        [[ -r "${2-}" ]] || { echo "xcresult-retries.sh: can't read ${2-}" >&2; exit 2; }
        json="$(cat "$2")"
        ;;
    ""|-h|--help) usage; exit 0 ;;
    *)
        if [[ ! -d "$1" ]]; then
            echo "xcresult-retries.sh: no result bundle at $1 (the test run didn't get that far)"
            exit 0
        fi
        json="$(xcrun xcresulttool get test-results tests --path "$1")"
        ;;
esac

# id <TAB> overall result <TAB> each attempt's result, for tests with both a failed and a passed attempt.
mixed="$(printf '%s' "$json" | jq -r '
    .. | objects | select(.nodeType == "Test Case")
    | ([.children[]? | select(.nodeType == "Repetition") | .result]) as $attempts
    | select(($attempts | index("Failed")) != null and ($attempts | index("Passed")) != null)
    | [(.nodeIdentifier // .name), .result, ($attempts | join(", "))] | @tsv')"

count=0
while IFS=$'\t' read -r test result attempts; do
    [[ -n "$test" ]] || continue
    count=$(( count + 1 ))
    if [[ "$result" == Passed ]]; then
        title="Passed on retry"
        message="$test failed, then passed on a retry ($attempts)"
    else
        title="Flaky test"
        message="$test passed some attempts and failed others ($attempts)"
    fi
    echo "::warning title=$title::$message"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then echo "- $title: \`$test\` ($attempts)" >> "$GITHUB_STEP_SUMMARY"; fi
done <<< "$mixed"
echo "xcresult-retries.sh: $count test(s) with attempts that disagreed"
