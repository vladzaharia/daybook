#!/bin/bash
# After an upload: waits for App Store Connect to process the build, sets its What to Test notes, and
# adds it to a TestFlight beta group. Uses the App Store Connect API with curl and jq, authenticated
# with a JWT from scripts/ci/asc-jwt.sh. No fastlane, no Ruby.
#
#   scripts/ci/asc-testflight.sh --bundle-id local.daybook --version 1.4.0 --build 1057 \
#       [--group "Daybook testers"] [--notes-file notes.txt] [--locale en-US] [--timeout 3600] [--platform IOS]
#   scripts/ci/asc-testflight.sh --bundle-id local.daybook --version 1.4.0 \
#       --find-build "1057 1057.2" [--uploaded-after 2026-10-24T20:11:08Z] [--platform IOS]
#
# --platform is IOS (the default) or MAC_OS: one app record holds both apps (universal purchase), and each
# platform has its own versions and builds there.
#
# --find-build only looks: it prints found=<build number> for the newest of those builds of --version
# that App Store Connect already has and that didn't fail processing (found= when there's none), and
# changes nothing. release.yml asks before archiving and again before uploading, with every number the
# run has used so far, so a re-run after a successful upload goes straight to TestFlight instead of
# uploading a duplicate. With --uploaded-after (the run's creation time), a build uploaded earlier
# can't be this run's: the build number collided with an older upload, and it fails.
#
# Environment (all three required):
#   DAYBOOK_ASC_KEY_PATH, DAYBOOK_ASC_KEY_ID, DAYBOOK_ASC_ISSUER_ID   the API key (scripts/ci/secrets.sh)
#   ASC_API_BASE    API root (default https://api.appstoreconnect.apple.com; tests point it at a mock)
#   ASC_POLL_SECONDS  seconds between processing checks (default 30)
#
# Steps:
#   1. GET  /v1/apps?filter[bundleId]=...                         the app record
#   2. GET  /v1/builds?filter[app]&filter[version]&filter[preReleaseVersion.version]&...platform=<--platform>
#      until processingState is VALID (FAILED or INVALID stops with an error, as does --timeout)
#   3. What to Test: PATCH the build's betaBuildLocalization for --locale, or POST one
#   4. GET  /v1/betaGroups?filter[app]&filter[name]  then  POST /v1/betaGroups/{id}/relationships/builds
#      For an external group, also POST /v1/betaAppReviewSubmissions (Beta App Review); App Store
#      Connect needs the app's Test Information filled in once for that.
# It also reports the build's usesNonExemptEncryption, which Info.plist's ITSAppUsesNonExemptEncryption
# (false, the owner's decision; docs/release.md) should have set without a question.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
api="${ASC_API_BASE:-https://api.appstoreconnect.apple.com}"
poll_seconds="${ASC_POLL_SECONDS:-30}"
bundle_id=""
version=""
build=""
group=""
notes_file=""
locale="en-US"
timeout=3600
find_builds=""
uploaded_after=""
platform=IOS

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
fail() { echo "asc-testflight.sh: $*" >&2; exit 1; }
note() { echo "asc-testflight.sh: $*" >&2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle-id) bundle_id="${2-}"; shift ;;
        --version) version="${2-}"; shift ;;
        --build) build="${2-}"; shift ;;
        --group) group="${2-}"; shift ;;
        --notes-file) notes_file="${2-}"; shift ;;
        --locale) locale="${2-}"; shift ;;
        --timeout) timeout="${2-}"; shift ;;
        --find-build) find_builds="${2-}"; shift ;;
        --uploaded-after) uploaded_after="${2-}"; shift ;;
        --platform) platform="${2-}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "unknown option: $1" ;;
    esac
    shift
done

[[ "$platform" == IOS || "$platform" == MAC_OS ]] || fail "--platform is IOS or MAC_OS"
if [[ -n "$find_builds" ]]; then
    [[ -n "$bundle_id" && -n "$version" ]] || { usage >&2; fail "--bundle-id and --version are required"; }
    [[ "$find_builds" =~ ^[0-9.]+( [0-9.]+)*$ ]] || fail "--find-build takes build numbers separated by spaces"
    if [[ -n "$uploaded_after" && ! "$uploaded_after" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}(\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})$ ]]; then
        fail "--uploaded-after must be an ISO 8601 time, such as 2026-10-24T20:11:08Z"
    fi
else
    [[ -n "$bundle_id" && -n "$version" && -n "$build" ]] || { usage >&2; fail "--bundle-id, --version, and --build are required"; }
fi
: "${DAYBOOK_ASC_KEY_PATH:?set DAYBOOK_ASC_KEY_PATH}" "${DAYBOOK_ASC_KEY_ID:?set DAYBOOK_ASC_KEY_ID}" "${DAYBOOK_ASC_ISSUER_ID:?set DAYBOOK_ASC_ISSUER_ID}"
[[ -z "$notes_file" || -r "$notes_file" ]] || fail "can't read --notes-file $notes_file"
command -v jq >/dev/null || fail "jq is required"

token=""
token_time=0
bearer() {
    local now
    now=$(date +%s)
    # Tokens last 19 minutes; make a new one after 15.
    if [[ -z "$token" ]] || (( now - token_time > 900 )); then
        token=$("$script_dir/asc-jwt.sh" --key "$DAYBOOK_ASC_KEY_PATH" --key-id "$DAYBOOK_ASC_KEY_ID" \
            --issuer-id "$DAYBOOK_ASC_ISSUER_ID")
        token_time=$now
    fi
}

response_body=""
response_status=""
# request METHOD PATH [JSON]: sets response_status and response_body. The token reaches curl through a
# header file readable only by this user, not the command line, so it never shows up in `ps`. Only GETs
# are retried on transient errors; a retried POST could act twice.
request() {
    local method="$1" path="$2" body="${3-}" out headers
    bearer
    out=$(mktemp)
    headers=$(mktemp)
    chmod 600 "$headers"
    printf 'Authorization: Bearer %s\n' "$token" > "$headers"
    local args=(-sS -X "$method" -H "@$headers" -H 'Accept: application/json' -o "$out" -w '%{http_code}'
                --connect-timeout 20 --max-time 120)
    [[ "$method" == GET ]] && args+=(--retry 3 --retry-delay 5)
    if [[ -n "$body" ]]; then
        args+=(-H 'Content-Type: application/json' --data-binary "$body")
    fi
    response_status=$(curl "${args[@]}" "$api$path") || response_status="000"
    response_body=$(cat "$out")
    rm -f "${out:?}" "${headers:?}"
}

# expect STATUS... : fails with Apple's error details unless the last status is one of them.
expect() {
    local ok
    for ok in "$@"; do [[ "$response_status" == "$ok" ]] && return 0; done
    local details
    details=$(printf '%s' "$response_body" | jq -r '.errors[]? | "  \(.status) \(.code): \(.title) \(.detail // "")"' 2>/dev/null || true)
    fail "HTTP $response_status from App Store Connect${details:+:
$details}"
}

uri() { jq -rn --arg v "$1" '$v|@uri'; }
# ISO 8601 (App Store Connect writes offsets such as -07:00, and fractions of a second) to Unix time.
epoch() {
    jq -rn --arg t "$1" '$t | capture("^(?<dt>[0-9-]+T[0-9:]+)(\\.[0-9]+)?(?<tz>Z|[+-][0-9]{2}:?[0-9]{2})$")
        | ((.dt + "Z") | fromdateiso8601) - (if .tz == "Z" then 0 else (.tz
            | capture("(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})")
            | (if .s == "-" then -1 else 1 end) * ((.h | tonumber) * 3600 + (.m | tonumber) * 60)) end)'
}

# 1. The app record.
request GET "/v1/apps?filter%5BbundleId%5D=$(uri "$bundle_id")&fields%5Bapps%5D=bundleId,name&limit=10"
expect 200
app_id=$(printf '%s' "$response_body" | jq -r --arg b "$bundle_id" '[.data[] | select(.attributes.bundleId == $b)][0].id // empty')
[[ -n "$app_id" ]] || fail "no App Store Connect app has the bundle ID $bundle_id. Create the app record first (docs/release.md, One-time setup)."
note "app $bundle_id is $app_id"

# --find-build: look, report, and stop.
if [[ -n "$find_builds" ]]; then
    query="/v1/builds?filter%5Bapp%5D=$app_id&filter%5Bversion%5D=$(uri "${find_builds// /,}")"
    query+="&filter%5BpreReleaseVersion.version%5D=$(uri "$version")&filter%5BpreReleaseVersion.platform%5D=$platform"
    query+="&fields%5Bbuilds%5D=version,processingState,uploadedDate,expired&sort=-uploadedDate&limit=50"
    request GET "$query"
    expect 200
    listed=$(printf '%s' "$response_body" | jq -r '.data[] | [.attributes.version, (.attributes.processingState // "?"), (.attributes.uploadedDate // ""), (.attributes.expired // false)] | @tsv')
    found=""
    while IFS=$'\t' read -r number state uploaded expired; do
        [[ -n "$number" ]] || continue
        flag=""
        [[ "$expired" == true ]] && flag=", expired"
        note "App Store Connect has $version ($number): $state, uploaded $uploaded$flag"
        if [[ -n "$uploaded_after" && -n "$uploaded" ]] && (( $(epoch "$uploaded") < $(epoch "$uploaded_after") )); then
            fail "$version ($number) was uploaded at $uploaded, before this run started ($uploaded_after), so it isn't this run's build: the build number collided with an earlier upload. Raise DAYBOOK_BUILD_NUMBER_OFFSET above the highest build number in App Store Connect and run the release again (docs/release.md, Versions)."
        fi
        case "$state" in
            FAILED|INVALID) continue ;;
        esac
        [[ "$expired" == true ]] && continue
        [[ -z "$found" ]] && found="$number"
    done <<< "$listed"
    if [[ -n "$found" ]]; then
        note "$version ($found) is already in App Store Connect; it doesn't need uploading again"
    else
        note "App Store Connect has no usable build $version (${find_builds// /, })"
    fi
    echo "found=$found"
    exit 0
fi

# 2. Wait for processing.
query="/v1/builds?filter%5Bapp%5D=$app_id&filter%5Bversion%5D=$(uri "$build")"
query+="&filter%5BpreReleaseVersion.version%5D=$(uri "$version")&filter%5BpreReleaseVersion.platform%5D=$platform"
query+="&fields%5Bbuilds%5D=version,processingState,usesNonExemptEncryption,expired&limit=1"
deadline=$(( $(date +%s) + timeout ))
build_id=""
while :; do
    request GET "$query"
    expect 200
    build_id=$(printf '%s' "$response_body" | jq -r '.data[0].id // empty')
    state=$(printf '%s' "$response_body" | jq -r '.data[0].attributes.processingState // empty')
    case "$state" in
        VALID) break ;;
        FAILED|INVALID) fail "App Store Connect marked build $version ($build) $state. Check the email App Store Connect sent and the build's page." ;;
        "") note "build $version ($build) isn't listed yet" ;;
        *) note "build $version ($build) is $state" ;;
    esac
    (( $(date +%s) < deadline )) || fail "build $version ($build) wasn't processed within $timeout seconds; it may still finish, then set notes and groups in App Store Connect."
    sleep "$poll_seconds"
done
encryption=$(printf '%s' "$response_body" | jq -r '.data[0].attributes.usesNonExemptEncryption')
note "build $version ($build) is $build_id, processed; usesNonExemptEncryption=$encryption"
if [[ "$encryption" == "null" ]]; then
    note "warning: App Store Connect is waiting for the export compliance answer: the archive should have carried ITSAppUsesNonExemptEncryption."
fi

# 3. What to Test.
if [[ -n "$notes_file" ]]; then
    # TestFlight allows 4,000 characters (jq slices by character, not byte).
    notes=$(jq -Rrs '.[0:4000]' < "$notes_file")
    request GET "/v1/builds/$build_id/betaBuildLocalizations?fields%5BbetaBuildLocalizations%5D=locale,whatsNew&limit=50"
    expect 200
    localization_id=$(printf '%s' "$response_body" | jq -r --arg l "$locale" '[.data[] | select(.attributes.locale == $l)][0].id // empty')
    if [[ -n "$localization_id" ]]; then
        body=$(jq -cn --arg id "$localization_id" --arg notes "$notes" \
            '{data: {type: "betaBuildLocalizations", id: $id, attributes: {whatsNew: $notes}}}')
        request PATCH "/v1/betaBuildLocalizations/$localization_id" "$body"
        expect 200
    else
        body=$(jq -cn --arg build "$build_id" --arg locale "$locale" --arg notes "$notes" \
            '{data: {type: "betaBuildLocalizations", attributes: {locale: $locale, whatsNew: $notes},
                     relationships: {build: {data: {type: "builds", id: $build}}}}}')
        request POST "/v1/betaBuildLocalizations" "$body"
        expect 201
    fi
    note "set What to Test ($locale, ${#notes} characters)"
fi

# 4. Beta group.
if [[ -n "$group" ]]; then
    request GET "/v1/betaGroups?filter%5Bapp%5D=$app_id&filter%5Bname%5D=$(uri "$group")&fields%5BbetaGroups%5D=name,isInternalGroup,hasAccessToAllBuilds&limit=50"
    expect 200
    group_id=$(printf '%s' "$response_body" | jq -r --arg g "$group" '[.data[] | select(.attributes.name == $g)][0].id // empty')
    if [[ -z "$group_id" ]]; then
        request GET "/v1/betaGroups?filter%5Bapp%5D=$app_id&fields%5BbetaGroups%5D=name&limit=50"
        known=$(printf '%s' "$response_body" | jq -r '[.data[]?.attributes.name] | join(", ")' 2>/dev/null || true)
        fail "no beta group named '$group' for $bundle_id. Groups: ${known:-none}"
    fi
    internal=$(printf '%s' "$response_body" | jq -r --arg g "$group" '[.data[] | select(.attributes.name == $g)][0].attributes.isInternalGroup')
    every_build=$(printf '%s' "$response_body" | jq -r --arg g "$group" '[.data[] | select(.attributes.name == $g)][0].attributes.hasAccessToAllBuilds // false')
    if [[ "$internal" == "true" && "$every_build" == "true" ]]; then
        # An internal group with access to all builds gets each one by itself; App Store Connect
        # refuses to add a build to it (422 "Builds cannot be assigned to this internal group").
        note "'$group' is an internal group that gets every build; nothing to add"
    else
        body=$(jq -cn --arg build "$build_id" '{data: [{type: "builds", id: $build}]}')
        request POST "/v1/betaGroups/$group_id/relationships/builds" "$body"
        expect 204
        note "added the build to '$group' (internal: $internal)"
    fi
    if [[ "$internal" != "true" ]]; then
        body=$(jq -cn --arg build "$build_id" \
            '{data: {type: "betaAppReviewSubmissions", relationships: {build: {data: {type: "builds", id: $build}}}}}')
        request POST "/v1/betaAppReviewSubmissions" "$body"
        if [[ "$response_status" == 409 ]]; then
            note "the build was already submitted for Beta App Review"
        else
            expect 201
            note "submitted the build for Beta App Review; external testers get it once it's approved"
        fi
    fi
fi

echo "build_id=$build_id"
