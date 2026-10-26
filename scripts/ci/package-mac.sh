#!/bin/bash
# Packages the exported Mac app for a GitHub Release: notarizes and staples it, then writes a ZIP, a
# DMG when one can be signed, and SHA256SUMS.txt.
#
#   scripts/ci/package-mac.sh --app dist/Daybook.app --version 1.4.0 [--build 1057] --output dist/release [--notarize]
#                             [--sandbox]
#
#   --version, --build   the app's Info.plist must carry these as CFBundleShortVersionString and
#                CFBundleVersion, or nothing is packaged
#   --notarize   submit to Apple's notary service with the App Store Connect API key
#                (DAYBOOK_ASC_KEY_PATH, DAYBOOK_ASC_KEY_ID, DAYBOOK_ASC_ISSUER_ID), wait, and staple.
#                Requires a Developer ID signature with the iCloud entitlements. Without it (local
#                checks), the app is packaged as it is and nothing is sent to Apple. With --notarize the
#                app's bundle ID, App Sandbox entitlements, and migration manifest are checked first
#                (scripts/ci/check-mac-app.sh): not sandboxed and no manifest, or with --sandbox, sandboxed,
#                no temporary exceptions, and the manifest that moves the library (docs/sandbox.md).
#   --sandbox    the app is the sandboxed build (build-app.sh --sandbox)
#   --wait 45m, --dmg-wait 20m
#                how long to wait for each submission (notarytool's --timeout). Apple usually takes
#                minutes; these keep the waits well inside the job's time limit.
#   --state-dir DIR
#                where the app's submission is kept while it's pending: submit.zip (exactly what was
#                sent) and pending.json (its submission ID, version, build, and SHA-256). If the wait
#                runs out with the submission still in progress, the script exits 75 and leaves them, so
#                release.yml can keep them for a re-run (scripts/ci/notary-resume.sh). Accepted or
#                rejected, pending.json is removed. Default: a temporary directory.
#   --submission ID
#                don't submit the app: wait for this earlier submission of the same app instead (a
#                re-run; notary-resume.sh restored the app and the state directory).
#
# Submission IDs and results also go to $GITHUB_STEP_SUMMARY when it's set. If the DMG's notarization
# doesn't finish in time, the DMG is left out (a warning) and the release ships the ZIP.
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
sandbox=0
app_wait="45m"
dmg_wait="20m"
state_dir=""
submission=""
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
        --sandbox) sandbox=1 ;;
        --wait) app_wait="${2-}"; shift ;;
        --dmg-wait) dmg_wait="${2-}"; shift ;;
        --state-dir) state_dir="${2-}"; shift ;;
        --submission) submission="${2-}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "unknown option: $1" ;;
    esac
    shift
done
[[ -d "$app" && -n "$version" && -n "$output" ]] || { usage >&2; fail "--app, --version, and --output are required"; }
[[ "$app_wait" =~ ^[0-9]+[smh]$ && "$dmg_wait" =~ ^[0-9]+[smh]$ ]] || fail "--wait and --dmg-wait take a duration such as 45m"
[[ -z "$submission" || "$submission" =~ ^[0-9a-fA-F-]{36}$ ]] || fail "--submission must be a notary submission ID"

name="Daybook-$version-macOS-arm64"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
zip="$output/$name.zip"
dmg="$output/$name.dmg"
work="$(mktemp -d)"
trap '/bin/rm -rf "${work:?}"' EXIT
state_dir="${state_dir:-$work/state}"
mkdir -p "$state_dir"

info="$app/Contents/Info.plist"
short="$(plutil -extract CFBundleShortVersionString raw -o - "$info" 2>/dev/null || true)"
long="$(plutil -extract CFBundleVersion raw -o - "$info" 2>/dev/null || true)"
[[ "$short" == "$version" ]] || fail "$app is version '$short' (CFBundleShortVersionString), not $version"
[[ -z "$build" || "$long" == "$build" ]] || fail "$app is build '$long' (CFBundleVersion), not $build"
echo "Version $short ($long)"

codesign --verify --deep --strict --verbose=2 "$app"
signature="$(codesign -dv --verbose=2 "$app" 2>&1)"
printf '%s\n' "$signature" | grep -E '^(Authority|TeamIdentifier|Identifier)=' || true

summary() { if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; fi; }
auth() { printf '%s\n' --key "$DAYBOOK_ASC_KEY_PATH" --key-id "$DAYBOOK_ASC_KEY_ID" --issuer "$DAYBOOK_ASC_ISSUER_ID"; }
notarytool() {
    local args=()
    while IFS= read -r arg; do args+=("$arg"); done < <(auth)
    xcrun notarytool "$@" "${args[@]}"
}
json_field() { jq -r --arg f "$1" '.[$f] // empty' 2>/dev/null || true; }

# submit FILE: sends FILE without waiting and prints the submission ID.
submit() {
    local result id
    result="$(notarytool submit "$1" --output-format json)" || { printf '%s\n' "$result" >&2; fail "couldn't submit $(basename "$1")"; }
    id="$(printf '%s' "$result" | json_field id)"
    [[ -n "$id" ]] || { printf '%s\n' "$result" >&2; fail "notarytool returned no submission ID for $(basename "$1")"; }
    printf '%s\n' "$id"
}

# await ID DURATION LABEL: waits up to DURATION, then prints Accepted, Invalid, Rejected, or In Progress.
await() {
    local id="$1" duration="$2" label="$3" status
    status="$(notarytool wait "$id" --timeout "$duration" --output-format json 2>/dev/null | json_field status)" || true
    case "$status" in
        Accepted|Invalid|Rejected) ;;
        *) status="$(notarytool info "$id" --output-format json 2>/dev/null | json_field status)" || true ;;
    esac
    echo "Notarization of $label: ${status:-no answer} (submission $id)" >&2
    summary "- Notarization of $label: submission \`$id\`, ${status:-no answer}"
    printf '%s\n' "${status:-In Progress}"
}

# rejected ID LABEL: prints Apple's log for the submission and fails.
rejected() {
    notarytool log "$1" >&2 || true
    fail "notarization of $2 wasn't accepted (submission $1); Apple's log is above"
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
    # A release is exactly the kind it says: never sandboxed by accident, never sandboxed without the manifest.
    kind=signed
    if (( sandbox )); then kind=signed-sandbox; fi
    "$(dirname "$0")/check-mac-app.sh" --app "$app" --kind "$kind" || fail "$app isn't the $kind build this release expects"

    summary "### Notarization"
    pending="$state_dir/pending.json"
    if [[ -n "$submission" ]]; then
        [[ -f "$pending" && "$(jq -r .id "$pending")" == "$submission" ]] \
            || fail "--submission $submission needs its pending.json in $state_dir (scripts/ci/notary-resume.sh)"
        echo "Waiting for the earlier submission $submission instead of submitting again"
    else
        ditto -c -k --sequesterRsrc --keepParent "$app" "$state_dir/submit.zip"
        submission="$(submit "$state_dir/submit.zip")"
        jq -n --arg id "$submission" --arg version "$version" --arg build "$long" \
            --arg sha256 "$(shasum -a 256 "$state_dir/submit.zip" | awk '{print $1}')" \
            --arg submitted "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{id: $id, version: $version, build: $build, sha256: $sha256, submitted: $submitted}' > "$pending"
        echo "Submitted $name for notarization: $submission"
    fi
    status="$(await "$submission" "$app_wait" "the app")"
    case "$status" in
        Accepted) /bin/rm -f "${pending:?}" ;;
        Invalid|Rejected) /bin/rm -f "${pending:?}"; rejected "$submission" "the app" ;;
        *)
            echo "::error title=Notarization still in progress::Apple hasn't finished submission $submission within $app_wait. Re-run the failed job: it picks this submission up instead of building again."
            exit 75
            ;;
    esac
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
        dmg_submission="$(submit "$dmg")"
        status="$(await "$dmg_submission" "$dmg_wait" "the DMG")"
        case "$status" in
            Accepted)
                xcrun stapler staple "$dmg"
                spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
                ;;
            Invalid|Rejected) rejected "$dmg_submission" "the DMG" ;;
            *)
                echo "::warning title=DMG left out::Apple hasn't finished notarizing the DMG (submission $dmg_submission) within $dmg_wait; this release ships the ZIP alone."
                /bin/rm -f "${dmg:?}"
                ;;
        esac
    fi
    if [[ -f "$dmg" ]]; then echo "DMG: $dmg"; fi
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
