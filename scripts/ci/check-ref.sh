#!/bin/bash
# Decides whether a ref may start a release: a v* tag on a commit that's on the default branch (pushed,
# or picked in a manual run), or a manual run from the default branch itself.
#
#   scripts/ci/check-ref.sh --event push --ref refs/tags/v1.4.0 --sha <commit> [--default-branch main]
#                           [--remote origin]
#
# Needs the full history with the remote's branches (actions/checkout with fetch-depth: 0), so
# <remote>/<default branch> can be compared with the tagged commit. Exit status 1 means the ref is refused;
# the message says why.
set -euo pipefail

event=""
ref=""
sha=""
default_branch="main"
remote="origin"

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
fail() { echo "check-ref.sh: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --event) event="${2-}"; shift ;;
        --ref) ref="${2-}"; shift ;;
        --sha) sha="${2-}"; shift ;;
        --default-branch) default_branch="${2-}"; shift ;;
        --remote) remote="${2-}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; echo "check-ref.sh: unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
[[ -n "$event" && -n "$ref" && -n "$sha" && -n "$default_branch" ]] \
    || { usage >&2; echo "check-ref.sh: --event, --ref, and --sha are required" >&2; exit 2; }

case "$ref" in
    refs/tags/v*)
        main="$remote/$default_branch"
        git rev-parse --verify --quiet "refs/remotes/$main" >/dev/null \
            || fail "$main isn't fetched; check out with fetch-depth: 0"
        # A tag object peels to its commit; a commit stays itself.
        commit="$(git rev-parse --verify --quiet "$sha^{commit}")" || fail "$sha isn't a commit in this checkout"
        if ! git merge-base --is-ancestor "$commit" "refs/remotes/$main"; then
            fail "${ref#refs/tags/} points at ${commit:0:12}, which isn't on $default_branch. Release only commits that are on $default_branch: merge first, then tag the merged commit."
        fi
        echo "check-ref.sh: ${ref#refs/tags/} (${commit:0:12}) is on $default_branch"
        ;;
    "refs/heads/$default_branch")
        [[ "$event" == workflow_dispatch ]] || fail "only a v* tag push or a manual run starts a release, not a $event to $default_branch"
        echo "check-ref.sh: manual run from $default_branch"
        ;;
    *)
        fail "releases run from a v* tag or from $default_branch, not $ref"
        ;;
esac
