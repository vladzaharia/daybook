#!/bin/bash
# Packages the exported Mac app for a GitHub Release: notarizes and staples it, then writes a ZIP, a
# DMG when one can be signed, and SHA256SUMS.txt.
#
#   scripts/ci/package-mac.sh --app dist/Daybook.app --version 1.4.0 [--build 1057] --output dist/release [--notarize]
#
#   --version, --build   the app's Info.plist must carry these as CFBundleShortVersionString and
#                CFBundleVersion, or nothing is packaged
#   --notarize   submit to Apple's notary service with the App Store Connect API key
#                (DAYBOOK_ASC_KEY_PATH, DAYBOOK_ASC_KEY_ID, DAYBOOK_ASC_ISSUER_ID), wait, and staple.
#                Requires a Developer ID signature with the iCloud entitlements. Without it (local
#                checks), the app is packaged as it is and nothing is sent to Apple.
#
# Outputs in --output:
#   Daybook-<version>-macOS-arm64.zip   the stapled app (ditto, keeps extended attributes)
#   Daybook-<version>-macOS-arm64.dmg   only when a Developer ID Application identity is in a keychain
#                                       (the .p12 fallback): signed, notarized, and stapled. Xcode's
#                                       cloud-managed certificate signs only inside -exportArchive, so a
#                                       cloud-signed release ships the ZIP alone. Without --notarize an
#                                       unsigned DMG is made, to check the packaging.
#   SHA256SUMS.txt                      `shasum -a 256 -c SHA256SUMS.txt` verifies the downloads
set -euo pipefail

app=""
version=""
build=""
output=""
notarize=0
container="${DAYBOOK_ICLOUD_CONTAINER:-iCloud.local.daybook}"
team="${DAYBOOK_TEAM_ID:-}"

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
fail() { echo "package-mac.sh: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) app="${2-}"; shift ;;
        --version) version="${2-}"; shift ;;
        --build) build="${2-}"; shift ;;
        --output) output="${2-}"; shift ;;
        --notarize) notarize=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "unknown option: $1" ;;
    esac
    shift
done
[[ -d "$app" && -n "$version" && -n "$output" ]] || { usage >&2; fail "--app, --version, and --output are required"; }

name="Daybook-$version-macOS-arm64"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
zip="$output/$name.zip"
dmg="$output/$name.dmg"
work="$(mktemp -d)"
trap '/bin/rm -rf "${work:?}"' EXIT

info="$app/Contents/Info.plist"
short="$(plutil -extract CFBundleShortVersionString raw -o - "$info" 2>/dev/null || true)"
long="$(plutil -extract CFBundleVersion raw -o - "$info" 2>/dev/null || true)"
[[ "$short" == "$version" ]] || fail "$app is version '$short' (CFBundleShortVersionString), not $version"
[[ -z "$build" || "$long" == "$build" ]] || fail "$app is build '$long' (CFBundleVersion), not $build"
echo "Version $short ($long)"

codesign --verify --deep --strict --verbose=2 "$app"
signature="$(codesign -dv --verbose=2 "$app" 2>&1)"
printf '%s\n' "$signature" | grep -E '^(Authority|TeamIdentifier|Identifier)=' || true

notary() {
    # notary FILE: submit, wait, and fail with Apple's log unless it's accepted.
    local file="$1" result id status
    result="$(xcrun notarytool submit "$file" --key "$DAYBOOK_ASC_KEY_PATH" --key-id "$DAYBOOK_ASC_KEY_ID" \
        --issuer "$DAYBOOK_ASC_ISSUER_ID" --wait --timeout 2h --output-format json)" || true
    id="$(printf '%s' "$result" | jq -r '.id // empty' 2>/dev/null || true)"
    status="$(printf '%s' "$result" | jq -r '.status // empty' 2>/dev/null || true)"
    echo "Notarization of $(basename "$file"): ${status:-no result} ${id:+(submission $id)}"
    if [[ "$status" != Accepted ]]; then
        printf '%s\n' "$result" >&2
        if [[ -n "$id" ]]; then
            xcrun notarytool log "$id" --key "$DAYBOOK_ASC_KEY_PATH" --key-id "$DAYBOOK_ASC_KEY_ID" \
                --issuer "$DAYBOOK_ASC_ISSUER_ID" >&2 || true
        fi
        fail "notarization of $(basename "$file") wasn't accepted"
    fi
}

if (( notarize )); then
    : "${DAYBOOK_ASC_KEY_PATH:?--notarize needs the API key (scripts/ci/secrets.sh setup)}"
    : "${DAYBOOK_ASC_KEY_ID:?}" "${DAYBOOK_ASC_ISSUER_ID:?}"
    printf '%s\n' "$signature" | grep -q '^Authority=Developer ID Application' \
        || fail "$app isn't signed with Developer ID Application"
    if [[ -n "$team" ]]; then
        printf '%s\n' "$signature" | grep -q "^TeamIdentifier=$team\$" || fail "$app isn't signed by team $team"
    fi
    entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null)"
    printf '%s' "$entitlements" | grep -q "<string>$container</string>" \
        || fail "$app lacks the $container entitlement: the export didn't use the Developer ID profile with iCloud"
    echo "Entitlements include $container"

    ditto -c -k --sequesterRsrc --keepParent "$app" "$work/submit.zip"
    notary "$work/submit.zip"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
fi

/bin/rm -f "${zip:?}"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
echo "ZIP: $zip"

identity=""
if (( notarize )); then
    # The .p12 fallback leaves a Developer ID Application identity in a keychain; prefer this team's.
    identities="$(security find-identity -v -p codesigning 2>/dev/null | grep '"Developer ID Application' || true)"
    if [[ -n "$team" ]]; then
        identity="$(printf '%s\n' "$identities" | grep "($team)\"" | awk '{print $2}' | head -1)"
    else
        identity="$(printf '%s\n' "$identities" | awk '{print $2}' | head -1)"
    fi
fi
/bin/rm -f "${dmg:?}"
if (( ! notarize )) || [[ -n "$identity" ]]; then
    staging="$work/dmg"
    mkdir -p "$staging"
    ditto "$app" "$staging/$(basename "$app")"
    ln -s /Applications "$staging/Applications"
    hdiutil create -quiet -volname "Daybook $version" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"
    if [[ -n "$identity" ]]; then
        codesign --sign "$identity" --timestamp "$dmg"
        notary "$dmg"
        xcrun stapler staple "$dmg"
        spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
    fi
    echo "DMG: $dmg"
else
    echo "No Developer ID identity in a keychain (cloud-managed signing): skipping the DMG."
fi

(
    cd "$output"
    files=()
    for file in "$name.zip" "$name.dmg"; do [[ -f "$file" ]] && files+=("$file"); done
    shasum -a 256 "${files[@]}" > SHA256SUMS.txt
    cat SHA256SUMS.txt
)
