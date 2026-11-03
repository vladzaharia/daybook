#!/bin/bash
# Approves a release run's distribution channels in one go: every channel it waits on, unless skipped.
# A skipped channel is rejected, so the run doesn't wait on it (docs/release.md, "Approving a release").
#
#   scripts/approve-release.sh [--run ID] [--skip ios-testflight|mac-testflight|mac-download]...
#       [--comment TEXT] [--repo OWNER/NAME] [--dry-run]
#
# Options:
#   --run ID       the Release run; default the newest one that's waiting
#   --skip KEY     reject that channel (repeatable): ios-testflight, mac-testflight, mac-download, or an
#                  environment's own name
#   --comment TEXT shown with the review on the run
#   --dry-run      say what would be approved and rejected, and change nothing
#
# Needs gh, authenticated as one of the environments' required reviewers. The web page does the same
# (the run's Review deployments, with each channel ticked); this ticks them all.
set -euo pipefail

repo=""
run=""
comment=""
dry_run=0
skips=()

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
fail() { echo "approve-release.sh: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) repo="${2-}"; shift ;;
        --run) run="${2-}"; shift ;;
        --skip) skips+=("${2-}"); shift ;;
        --comment) comment="${2-}"; shift ;;
        --dry-run) dry_run=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; echo "approve-release.sh: unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
for tool in gh jq; do command -v "$tool" >/dev/null || fail "$tool is required"; done
[[ -z "$run" || "$run" =~ ^[0-9]+$ ]] || fail "--run must be a run ID"

# A skip key's environment: the channels by their keys, or any environment by its own name.
skipped=()
for key in ${skips[@]+"${skips[@]}"}; do
    case "$key" in
        ios-testflight) skipped+=("iOS TestFlight") ;;
        mac-testflight) skipped+=("Mac TestFlight") ;;
        mac-download) skipped+=("Mac download") ;;
        "") fail "--skip needs a channel" ;;
        *) skipped+=("$key") ;;
    esac
done

if [[ -z "$repo" ]]; then
    repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || fail "pass --repo OWNER/NAME"
fi
if [[ -z "$run" ]]; then
    run="$(gh run list --repo "$repo" --workflow release.yml --status waiting --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
    [[ -n "$run" ]] || fail "no Release run is waiting for approval"
fi

pending="$(gh api "repos/$repo/actions/runs/$run/pending_deployments")"
[[ "$(jq 'length' <<< "$pending")" != 0 ]] || fail "run $run isn't waiting on any channel"
skipped_json="$(printf '%s\n' ${skipped[@]+"${skipped[@]}"} | jq -R -s 'split("\n") | map(select(length > 0))')"
for name in ${skipped[@]+"${skipped[@]}"}; do
    jq -e --arg name "$name" 'any(.[]; .environment.name == $name)' <<< "$pending" >/dev/null \
        || echo "approve-release.sh: run $run isn't waiting on '$name'; nothing to skip there" >&2
done
blocked="$(jq -r '[.[] | select(.current_user_can_approve == false) | .environment.name] | join(", ")' <<< "$pending")"
[[ -z "$blocked" ]] || fail "you can't approve $blocked on run $run (not a required reviewer)"

approve="$(jq -c --argjson skipped "$skipped_json" '[.[] | select(.environment.name as $n | $skipped | index($n) | not) | .environment]' <<< "$pending")"
reject="$(jq -c --argjson skipped "$skipped_json" '[.[] | select(.environment.name as $n | $skipped | index($n)) | .environment]' <<< "$pending")"

review() {
    local state="$1" environments="$2"
    [[ "$(jq 'length' <<< "$environments")" != 0 ]] || return 0
    echo "$state: $(jq -r 'map(.name) | join(", ")' <<< "$environments")"
    (( dry_run )) && return 0
    jq -n --argjson environments "$environments" --arg state "$state" --arg comment "$comment" \
        '{environment_ids: ($environments | map(.id)), state: $state, comment: $comment}' \
        | gh api -X POST "repos/$repo/actions/runs/$run/pending_deployments" --input - --silent
}

echo "Release run $run (https://github.com/$repo/actions/runs/$run)"
review approved "$approve"
review rejected "$reject"
(( dry_run )) && echo "(dry run: nothing changed)"
exit 0
