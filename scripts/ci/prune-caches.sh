#!/bin/bash
# After CI on main has saved its caches: deletes the older caches of the same families, so caches for
# superseded project hashes don't crowd the repository's 10 GB quota (docs/release.md, CI details).
#
#   scripts/ci/prune-caches.sh --repo OWNER/NAME [--ref refs/heads/main] KEY...
#
# Each KEY is one a CI job used in this run, e.g. swiftpm-macOS-27A9275-<hash>; its family is the key
# without the last "-<hash>" part, the prefix the job restores from. If KEY is among the caches on
# --ref, every other cache of its family there is deleted. If it isn't (the save failed, or was
# skipped), the family is left alone, so a failed run never deletes the last good cache. Needs gh with
# GH_TOKEN (actions: write).
set -euo pipefail

repo=""
ref="refs/heads/main"
keys=()

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
fail() { echo "prune-caches.sh: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) repo="${2-}"; shift ;;
        --ref) ref="${2-}"; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) usage >&2; fail "unknown option: $1" ;;
        *) keys+=("$1") ;;
    esac
    shift
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "--repo must be OWNER/NAME"
[[ "$ref" =~ ^refs/heads/[A-Za-z0-9_./-]+$ ]] || fail "--ref must be a branch ref such as refs/heads/main"

deleted=0
for key in ${keys[@]+"${keys[@]}"}; do
    [[ "$key" =~ ^[A-Za-z0-9_.-]+-[0-9a-f]{16,}$ ]] || fail "'$key' isn't a cache key ending in a hash"
    family="${key%-*}-"
    listing="$(gh api "repos/$repo/actions/caches?ref=$ref&key=$family&per_page=100" \
        --jq '.actions_caches[] | "\(.id)\t\(.key)"')"
    if ! printf '%s\n' "$listing" | cut -f2 | grep -qxF -- "$key"; then
        echo "$key isn't saved on $ref; leaving the $family* caches alone"
        continue
    fi
    while IFS=$'\t' read -r id old; do
        [[ -n "$id" && "$old" != "$key" ]] || continue
        # A longer family (e.g. mac-dd-…-Debug- vs mac-dd-…-) never matches: the prefix includes the dash.
        [[ "${old%-*}-" == "$family" ]] || continue
        gh api -X DELETE "repos/$repo/actions/caches/$id" --silent
        echo "deleted $old (superseded by $key)"
        deleted=$(( deleted + 1 ))
    done <<< "$listing"
done
echo "deleted $deleted cache(s)"
