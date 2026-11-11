#!/bin/bash
# What CI's builds and tests have to check for a pull request: a change confined to one app doesn't need the other's
# jobs, and one that changes only documentation (docs/, and Markdown outside the apps' sources) needs none. Every other
# event always checks everything: a push to main is what a release waits for, and saves the caches (docs/release.md, CI).
#
#   scripts/ci/changes.sh --event EVENT [--base REV]
#
# --event  github.event_name; only pull_request can skip
# --base   what the change is compared with (default HEAD^1: the base side of a pull request's merge commit)
#
# Prints, for $GITHUB_OUTPUT, one line each:
#   package=true|false   the Swift package's build and tests (ci.yml's package job)
#   iphone=true|false    the iPhone app's tests and Release archive (iphone, iphone-archive)
#   mac=true|false       the Mac app's Xcode build (mac)
#   code=true|false      any of them
# and, on standard error, the first file that selected each.
#
# Each changed file selects the jobs that build it; a file not placed here selects them all:
#   Apps/iOS/                  iphone
#   Apps/macOS/, Resources/    mac (Resources/Daybook.icon is the iPhone app's icon too: iphone and mac)
#   Sources/Daybook/           package and mac (the Mac app's own sources, which the package's Daybook target builds)
#   Tests/DaybookTests/        package (the Mac app's tests run in the package job)
set -euo pipefail

event=""
base="HEAD^1"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --event) event="${2-}"; shift ;;
        --base) base="${2-}"; shift ;;
        *) echo "changes.sh: unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
[[ -n "$event" ]] || { echo "changes.sh: --event is required" >&2; exit 2; }

everything() { printf 'package=true\niphone=true\nmac=true\ncode=true\n'; }

if [[ "$event" != pull_request ]]; then
    everything
    exit 0
fi
files="$(git diff --name-only "$base" HEAD)" || { echo "changes.sh: can't compare with $base; checking everything" >&2; everything; exit 0; }
if [[ -z "$files" ]]; then
    everything
    exit 0
fi

package="" iphone="" mac=""
needs() {
    local job
    for job in "$@"; do
        if [[ -z "${!job}" ]]; then printf -v "$job" '%s' "$file"; fi
    done
}
while IFS= read -r file; do
    case "$file" in
        # Markdown the apps bundle (the notices) or read as source is code; other Markdown, and docs/, isn't.
        Sources/*|Apps/*|Tests/*|Resources/*|THIRD_PARTY_NOTICES.md) ;;
        docs/*|*.md) continue ;;
    esac
    case "$file" in
        Apps/iOS/*) needs iphone ;;
        Resources/Daybook.icon/*) needs iphone mac ;;
        Apps/macOS/*|Resources/*) needs mac ;;
        Sources/Daybook/*) needs package mac ;;
        Tests/DaybookTests/*) needs package ;;
        *) needs package iphone mac ;;
    esac
done <<< "$files"

code=false
for job in package iphone mac; do
    if [[ -n "${!job}" ]]; then
        echo "changes.sh: $job, for $(printf '%s' "${!job}")" >&2
        code=true
    fi
done
[[ "$code" == true ]] || echo "changes.sh: documentation only: $(wc -l <<< "$files" | tr -d ' ') files" >&2
printf 'package=%s\niphone=%s\nmac=%s\ncode=%s\n' \
    "$([[ -n "$package" ]] && echo true || echo false)" \
    "$([[ -n "$iphone" ]] && echo true || echo false)" \
    "$([[ -n "$mac" ]] && echo true || echo false)" "$code"
