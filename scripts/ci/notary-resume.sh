#!/bin/bash
# On a re-run of release.yml's mac job: picks up the app notarization an earlier attempt left pending
# (package-mac.sh --state-dir, kept as the mac-notarization-<attempt> artifact) instead of building
# and submitting again.
#
#   scripts/ci/notary-resume.sh --from build/notarization-earlier --state-dir build/notarization/attempt-2 \
#       --app dist/Daybook.app --version 1.4.0
#
# --from holds attempt-<n>/pending.json and attempt-<n>/submit.zip; the newest attempt counts. If its
# submission is for --version, its submit.zip is intact (SHA-256), and Apple says it's Accepted or still
# In Progress, the script copies both into --state-dir, unpacks the submitted app to --app, and prints
# submission=<id> and build=<its build number>. package-mac.sh --submission <id> then waits for it and
# staples. Otherwise (nothing pending, or the submission was rejected) it prints submission= and the
# job builds again. Needs DAYBOOK_ASC_KEY_PATH, DAYBOOK_ASC_KEY_ID, and DAYBOOK_ASC_ISSUER_ID.
set -euo pipefail

from=""
state_dir=""
app=""
version=""

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
fail() { echo "notary-resume.sh: $*" >&2; exit 1; }
note() { echo "notary-resume.sh: $*" >&2; }
start_over() { note "$*; building and submitting again"; echo "submission="; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from) from="${2-}"; shift ;;
        --state-dir) state_dir="${2-}"; shift ;;
        --app) app="${2-}"; shift ;;
        --version) version="${2-}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "unknown option: $1" ;;
    esac
    shift
done
[[ -n "$from" && -n "$state_dir" && -n "$app" && -n "$version" ]] || { usage >&2; fail "--from, --state-dir, --app, and --version are required"; }

latest=""
latest_attempt=0
for dir in "$from"/attempt-*; do
    [[ -f "$dir/pending.json" ]] || continue
    attempt="${dir##*/attempt-}"
    [[ "$attempt" =~ ^[0-9]+$ ]] || continue
    if (( attempt > latest_attempt )); then latest="$dir"; latest_attempt="$attempt"; fi
done
if [[ -z "$latest" ]]; then
    note "no notarization left pending by an earlier attempt"
    echo "submission="
    exit 0
fi

id="$(jq -r '.id // empty' "$latest/pending.json")"
pending_version="$(jq -r '.version // empty' "$latest/pending.json")"
pending_build="$(jq -r '.build // empty' "$latest/pending.json")"
sha256="$(jq -r '.sha256 // empty' "$latest/pending.json")"
[[ "$id" =~ ^[0-9a-fA-F-]{36}$ ]] || start_over "attempt $latest_attempt's pending.json has no submission ID"
[[ "$pending_version" == "$version" ]] || start_over "attempt $latest_attempt's submission $id is for version $pending_version, not $version"
[[ -f "$latest/submit.zip" && "$(shasum -a 256 "$latest/submit.zip" | awk '{print $1}')" == "$sha256" ]] \
    || start_over "attempt $latest_attempt's submit.zip doesn't match its checksum"

: "${DAYBOOK_ASC_KEY_PATH:?set DAYBOOK_ASC_KEY_PATH}" "${DAYBOOK_ASC_KEY_ID:?set DAYBOOK_ASC_KEY_ID}" "${DAYBOOK_ASC_ISSUER_ID:?set DAYBOOK_ASC_ISSUER_ID}"
status="$(xcrun notarytool info "$id" --key "$DAYBOOK_ASC_KEY_PATH" --key-id "$DAYBOOK_ASC_KEY_ID" \
    --issuer "$DAYBOOK_ASC_ISSUER_ID" --output-format json 2>/dev/null | jq -r '.status // empty' 2>/dev/null)" || true
case "$status" in
    Accepted|"In Progress") ;;
    *) start_over "attempt $latest_attempt's submission $id is ${status:-unknown to the notary service}" ;;
esac

mkdir -p "$state_dir"
/bin/cp -f "$latest/pending.json" "$latest/submit.zip" "$state_dir/"
if [[ -d "$app" ]]; then chmod -R u+w "$app"; fi
/bin/rm -rf "${app:?}"
mkdir -p "$(dirname "$app")"
ditto -x -k "$state_dir/submit.zip" "$(dirname "$app")"
[[ -d "$app" ]] || fail "$state_dir/submit.zip didn't contain $(basename "$app")"
note "resuming attempt $latest_attempt's submission $id ($status): $version ($pending_build)"
echo "submission=$id"
echo "build=$pending_build"
