#!/bin/bash
# Holds a release job until the release commit's tests have passed, before it uploads anything: CI's run for
# the commit on main (--ci-run), or, when main has none, this run's own validation (--run). The signing jobs
# start, and ask for approval, without waiting for the tests; this is where they wait (docs/release.md,
# "Validation").
#
#   scripts/ci/await-validation.sh --repo OWNER/NAME (--ci-run ID | --run ID) [--timeout MINUTES] [--interval SECONDS]
#
# --ci-run   a CI run; passes when its latest attempt succeeded
# --run      a Release run; passes when every job named "Validate the release commit / …" in its latest
#            attempt succeeded or was skipped
# --timeout  give up after this many minutes (default 150); --interval  seconds between checks (default 30)
#
# Exits 0 once the tests have passed, and 1 as soon as one fails or is cancelled, or when the time runs out. A
# check that can't reach GitHub is tried again at the next interval; only the timeout ends the wait for that.
# Needs gh with GH_TOKEN (actions: read).
set -euo pipefail

repo=""
ci_run=""
run=""
timeout=150
interval=30

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
fail() { echo "::error::await-validation.sh: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) repo="${2-}"; shift ;;
        --ci-run) ci_run="${2-}"; shift ;;
        --run) run="${2-}"; shift ;;
        --timeout) timeout="${2-}"; shift ;;
        --interval) interval="${2-}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; echo "await-validation.sh: unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
[[ "$repo" == */* ]] || { echo "await-validation.sh: --repo OWNER/NAME is required" >&2; exit 2; }
if [[ -z "$ci_run$run" || ( -n "$ci_run" && -n "$run" ) ]]; then echo "await-validation.sh: pass one of --ci-run and --run" >&2; exit 2; fi
for number in "$ci_run$run" "$timeout" "$interval"; do
    [[ "$number" =~ ^[0-9]+$ ]] || { echo "await-validation.sh: '$number' isn't a number" >&2; exit 2; }
done

deadline=$(( $(date +%s) + timeout * 60 ))
while :; do
    if [[ -n "$ci_run" ]]; then
        url="https://github.com/$repo/actions/runs/$ci_run"
        # A call that fails (the API unreachable for a moment) is tried again at the next check, not the end of the wait.
        if ! state="$(gh api "repos/$repo/actions/runs/$ci_run" --jq '"\(.status) \(.conclusion // "")"' 2>&1)"; then
            echo "Couldn't read CI's run ($url): ${state//$'\n'/ }; trying again in $interval s"
            sleep "$interval"; continue
        fi
        case "$state" in
            "completed success") echo "CI passed on this commit: $url"; exit 0 ;;
            completed*) fail "CI on main didn't pass on this commit (${state#completed }): $url. Re-run its failed jobs, then this one." ;;
        esac
        waiting="CI on main is ${state% *} ($url)"
    else
        if ! jobs="$(gh api --paginate "repos/$repo/actions/runs/$run/jobs?filter=latest&per_page=100" \
            --jq '.jobs[] | select(.name | startswith("Validate the release commit / ")) | "\(.status)\t\(.conclusion // "-")\t\(.name)"' 2>&1)"; then
            echo "Couldn't read the run's jobs: ${jobs//$'\n'/ }; trying again in $interval s"
            sleep "$interval"; continue
        fi
        failed="$(awk -F'\t' '$1 == "completed" && $2 != "success" && $2 != "skipped" { print $3 " (" $2 ")" }' <<< "$jobs")"
        [[ -z "$failed" ]] || fail "validation didn't pass: ${failed//$'\n'/, }"
        total="$(grep -c . <<< "$jobs" || true)"
        pending="$(awk -F'\t' 'NF && $1 != "completed"' <<< "$jobs" | grep -c . || true)"
        if (( total > 0 && pending == 0 )); then echo "Validation passed: $total jobs"; exit 0; fi
        if (( total == 0 )); then waiting="validation hasn't started"; else waiting="$pending of $total validation jobs still running"; fi
    fi
    (( $(date +%s) < deadline )) || fail "gave up after $timeout minutes: $waiting"
    echo "Waiting: $waiting"
    sleep "$interval"
done
