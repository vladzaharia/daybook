#!/bin/bash
# Downloads the active, manually managed provisioning profile of one type for one bundle ID from App
# Store Connect and installs it where Xcode looks, so an export can sign manually (Xcode refuses
# Xcode-managed profiles there, such as "Mac Team Direct Provisioning Profile: …"). The release pipeline uses it for the
# Mac app's Developer ID export: with a team API key, Xcode's automatic export insists on cloud-managed
# Developer ID signing, which Apple reserves for the Account Holder (docs/release.md, "Fallback: a
# Developer ID .p12").
#
#   scripts/ci/asc-profile.sh --bundle-id local.daybook.app --type MAC_APP_DIRECT \
#       [--keychain "$DAYBOOK_SIGNING_KEYCHAIN"] [--install-dir DIR]
#
# With --keychain, the profile must contain the certificate of that keychain's Developer ID
# Application identity, or the script fails before any export is attempted. Prints the profile's name
# to stderr and its UUID on stdout. Needs DAYBOOK_ASC_KEY_PATH, DAYBOOK_ASC_KEY_ID, and
# DAYBOOK_ASC_ISSUER_ID (scripts/ci/secrets.sh setup), curl, jq, and security. Read-only: it never
# creates or changes anything in App Store Connect.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
api="https://api.appstoreconnect.apple.com"
bundle_id=""
profile_type=""
keychain=""
install_dirs=("$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles")

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
fail() { echo "asc-profile.sh: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bundle-id) bundle_id="${2-}"; shift ;;
        --type) profile_type="${2-}"; shift ;;
        --keychain) keychain="${2-}"; shift ;;
        --install-dir) install_dirs=("${2-}"); shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "unknown option: $1" ;;
    esac
    shift
done

[[ -n "$bundle_id" && -n "$profile_type" ]] || { usage >&2; fail "--bundle-id and --type are required"; }
: "${DAYBOOK_ASC_KEY_PATH:?set DAYBOOK_ASC_KEY_PATH}" "${DAYBOOK_ASC_KEY_ID:?set DAYBOOK_ASC_KEY_ID}" "${DAYBOOK_ASC_ISSUER_ID:?set DAYBOOK_ASC_ISSUER_ID}"
command -v jq >/dev/null || fail "jq is required"

token=$("$script_dir/asc-jwt.sh" --key "$DAYBOOK_ASC_KEY_PATH" --key-id "$DAYBOOK_ASC_KEY_ID" --issuer-id "$DAYBOOK_ASC_ISSUER_ID")
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT
chmod 700 "$work"
# The token reaches curl through a header file readable only by this user, not the command line.
printf 'Authorization: Bearer %s\n' "$token" > "$work/headers"
chmod 600 "$work/headers"

response_body=""
get() {
    local status
    status=$(curl -sS -H "@$work/headers" -H 'Accept: application/json' -o "$work/body" -w '%{http_code}' \
        --connect-timeout 20 --max-time 120 --retry 3 --retry-delay 5 "$api$1") || status="000"
    response_body=$(cat "$work/body")
    if [[ "$status" != 200 ]]; then
        local details
        details=$(printf '%s' "$response_body" | jq -r '.errors[]? | "  \(.status) \(.code): \(.title) \(.detail // "")"' 2>/dev/null || true)
        fail "HTTP $status from App Store Connect for $1${details:+:
$details}"
    fi
}
uri() { jq -rn --arg v "$1" '$v|@uri'; }

get "/v1/bundleIds?filter%5Bidentifier%5D=$(uri "$bundle_id")&fields%5BbundleIds%5D=identifier&limit=20"
bundle_ref=$(printf '%s' "$response_body" | jq -r --arg b "$bundle_id" '[.data[] | select(.attributes.identifier == $b)][0].id // empty')
[[ -n "$bundle_ref" ]] || fail "no bundle ID $bundle_id in App Store Connect"

get "/v1/bundleIds/$bundle_ref/profiles?fields%5Bprofiles%5D=name,profileType,profileState,uuid,expirationDate,profileContent&limit=200"
# Newest first; the first one that isn't Xcode managed wins.
printf '%s' "$response_body" | jq -c --arg t "$profile_type" \
    '[.data[] | select(.attributes.profileType == $t and .attributes.profileState == "ACTIVE")] | sort_by(.attributes.expirationDate) | reverse | .[]' \
    > "$work/candidates"
profile=""
while IFS= read -r candidate; do
    printf '%s' "$candidate" | jq -r '.attributes.profileContent' | base64 -D > "$work/profile.provisionprofile"
    security cms -D -i "$work/profile.provisionprofile" > "$work/profile.plist" 2>/dev/null || continue
    [[ "$(plutil -extract IsXcodeManaged raw -o - "$work/profile.plist" 2>/dev/null || echo false)" == true ]] && continue
    profile="$candidate"
    break
done < "$work/candidates"
[[ -n "$profile" ]] || fail "no active, manually managed $profile_type profile for $bundle_id (Xcode-managed ones can't sign a manual export). Create one in Certificates, Identifiers & Profiles with the Developer ID Application certificate (docs/release.md)."
name=$(printf '%s' "$profile" | jq -r '.attributes.name')
uuid=$(printf '%s' "$profile" | jq -r '.attributes.uuid')
[[ "$uuid" =~ ^[0-9A-Fa-f-]{36}$ ]] || fail "the profile has no UUID"

if [[ -n "$keychain" ]]; then
    want=$(security find-identity -v -p codesigning "$keychain" | awk '/"Developer ID Application/ { print $2; exit }')
    [[ -n "$want" ]] || fail "no Developer ID Application identity in $keychain"
    found=""
    count=$(plutil -extract DeveloperCertificates raw -o - "$work/profile.plist" 2>/dev/null || echo 0)
    for (( i = 0; i < count; i++ )); do
        sha=$(plutil -extract "DeveloperCertificates.$i" raw -o - "$work/profile.plist" | base64 -D | shasum -a 1 | awk '{ print toupper($1) }')
        [[ "$sha" == "$want" ]] && found=yes
    done
    [[ -n "$found" ]] || fail "\"$name\" doesn't contain the certificate of the Developer ID identity in $keychain ($want). Regenerate the profile with that certificate in Certificates, Identifiers & Profiles."
fi

for dir in "${install_dirs[@]}"; do
    mkdir -p "$dir"
    cp "$work/profile.provisionprofile" "$dir/$uuid.provisionprofile"
done
echo "asc-profile.sh: installed \"$name\" ($uuid)" >&2
printf '%s\n' "$uuid"
