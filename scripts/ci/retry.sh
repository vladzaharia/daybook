#!/bin/bash
# Runs a command, and once more if it fails: for the two timing-budget tests only (docs/release.md, CI).
#
#   scripts/ci/retry.sh <attempts> <command> [arguments...]
#
# Each failed attempt is reported as a warning annotation, so a pass on the second try stays visible
# in the run summary instead of disappearing.
set -euo pipefail

attempts="${1:?usage: retry.sh <attempts> <command> [arguments...]}"
shift
[[ "$attempts" =~ ^[1-9][0-9]*$ ]] || { echo "retry.sh: attempts must be a positive integer" >&2; exit 2; }
for (( attempt = 1; ; attempt++ )); do
    if "$@"; then
        (( attempt > 1 )) && echo "::warning title=Passed on retry::$* passed on attempt $attempt of $attempts"
        exit 0
    else
        status=$?
    fi
    if (( attempt >= attempts )); then
        echo "::error title=Failed after $attempts attempts::$*"
        exit "$status"
    fi
    echo "::warning title=Retrying::$* failed (exit $status) on attempt $attempt of $attempts; retrying"
done
