#!/bin/bash
# Writes release notes for a tag or a commit: the annotated tag's message, if it has one, then the
# commits since the previous release tag.
#
#   scripts/ci/release-notes.sh --ref v1.4.0 [--format markdown|text] [--limit 60]
#   scripts/ci/release-notes.sh --ref HEAD --format text          (a TestFlight build from main)
#
# markdown (default) is for the GitHub Release; text is for TestFlight's What to Test, which shows
# plain text and allows 4,000 characters (asc-testflight.sh trims to that). The previous tag is the
# newest v* tag reachable from the ref's parent; with none, the history is listed from the start.
# Needs the full history and tags (actions/checkout with fetch-depth: 0).
set -euo pipefail

ref="HEAD"
format="markdown"
limit=60

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ref) ref="${2-}"; shift ;;
        --format) format="${2-}"; shift ;;
        --limit) limit="${2-}"; shift ;;
        *) echo "release-notes.sh: unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
[[ "$format" == markdown || "$format" == text ]] || { echo "release-notes.sh: --format is markdown or text" >&2; exit 2; }
[[ "$limit" =~ ^[1-9][0-9]*$ ]] || { echo "release-notes.sh: --limit must be a positive integer" >&2; exit 2; }

commit="$(git rev-parse --verify "$ref^{commit}")"
previous="$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$commit^" 2>/dev/null || true)"

# An annotated tag's message, without a PGP signature block.
message=""
if [[ "$(git cat-file -t "$ref" 2>/dev/null || true)" == tag ]]; then
    message="$(git tag -l --format='%(contents)' "${ref#refs/tags/}" | sed '/-----BEGIN PGP SIGNATURE-----/,$d')"
fi

range="$commit"
[[ -n "$previous" ]] && range="$previous..$commit"
total="$(git rev-list --count --no-merges "$range")"
if [[ "$format" == markdown ]]; then
    commits="$(git log --no-merges --max-count="$limit" --format='- %s (%h)' "$range")"
else
    commits="$(git log --no-merges --max-count="$limit" --format='- %s' "$range")"
fi

if [[ -n "$message" ]]; then
    printf '%s\n\n' "$message"
fi
if [[ "$format" == markdown ]]; then
    if [[ -n "$previous" ]]; then
        printf '## Changes since %s\n\n' "$previous"
    else
        printf '## Changes\n\n'
    fi
else
    if [[ -n "$previous" ]]; then
        printf 'Changes since %s:\n' "$previous"
    else
        printf 'Changes:\n'
    fi
fi
if [[ -n "$commits" ]]; then
    printf '%s\n' "$commits"
else
    printf -- '- No changes.\n'
fi
if (( total > limit )); then
    printf -- '- ...and %d more.\n' "$(( total - limit ))"
fi
if [[ "$format" == markdown ]]; then
    # shellcheck disable=SC2016 # the backticks are Markdown
    printf '\nThe Mac app is signed with Developer ID and notarized. Verify a download with `shasum -a 256 -c SHA256SUMS.txt`.\n'
fi
