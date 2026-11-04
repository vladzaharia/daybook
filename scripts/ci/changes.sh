#!/bin/bash
# Whether CI's builds and tests have anything to check: a pull request that changes only documentation (docs/, and
# Markdown outside the apps' sources) doesn't need them. Every other event always does: a push to main is what a
# release waits for, and saves the caches (docs/release.md, CI).
#
#   scripts/ci/changes.sh --event EVENT [--base REV]
#
# --event  github.event_name; only pull_request can skip
# --base   what the change is compared with (default HEAD^1: the base side of a pull request's merge commit)
#
# Prints code=true or code=false, for $GITHUB_OUTPUT, and the files that decided it on standard error.
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

if [[ "$event" != pull_request ]]; then
    echo "code=true"
    exit 0
fi
files="$(git diff --name-only "$base" HEAD)" || { echo "changes.sh: can't compare with $base; checking everything" >&2; echo "code=true"; exit 0; }
# Markdown the apps bundle (the notices) or read as source is code.
code="$(grep -vE '^docs/|\.md$' <<< "$files" || true)"
code+="$(grep -E '^(Sources|Apps|Tests|Resources)/.*\.md$|^THIRD_PARTY_NOTICES\.md$' <<< "$files" || true)"
if [[ -z "$files" || -n "$code" ]]; then
    [[ -z "$code" ]] || echo "changes.sh: code changed: $(head -3 <<< "$code" | paste -sd, -)" >&2
    echo "code=true"
else
    echo "changes.sh: documentation only: $(wc -l <<< "$files" | tr -d ' ') files" >&2
    echo "code=false"
fi
