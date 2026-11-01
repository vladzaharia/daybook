#!/bin/bash
# Checks an iPhone archive before it's exported and uploaded, so a build never stalls or bounces in
# App Store Connect for something visible in the archive.
#
#   scripts/ci/check-ios-archive.sh <DaybookPhone.xcarchive> [--version X.Y.Z] [--build N]
#
# Fails when:
#   - the app's Info.plist doesn't set ITSAppUsesNonExemptEncryption to false. That's the owner's
#     export compliance answer (Daybook uses only exempt encryption: TLS and CryptoKit; see
#     docs/release.md). Without the key, TestFlight holds every build at "Missing Compliance".
#   - the app has no app icon (no CFBundleIcons in Info.plist). App Store Connect rejects such an
#     upload (ITMS-90713 / ITMS-90022).
#   - the app runs on iPad (UIDeviceFamily isn't [1]). Daybook is iPhone only, and an iPad app must
#     list all four orientations for multitasking or App Store Connect rejects the upload.
#   - an App Intent's title, description, short title, or phrase names an Apple product (iPhone,
#     iPad, iPod, Apple, Siri). Processing rejects such a build after the upload (ITMS-90626), so it
#     never reaches TestFlight.
#   - CFBundleShortVersionString or CFBundleVersion of the app or any extension differs from
#     --version / --build (an extension must match its app).
#   - a bundle identifier isn't the expected one (local.daybook, local.daybook.widgets).
#   - the archive is signed and the app lacks the app group or iCloud container entitlements, or its keychain groups
#     aren't its own and then the shared one (library keys for an encrypted library).
set -euo pipefail

archive=""
version=""
build=""
container="${DAYBOOK_ICLOUD_CONTAINER:-iCloud.local.daybook}"
failures=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) version="${2-}"; shift ;;
        --build) build="${2-}"; shift ;;
        -*) echo "check-ios-archive.sh: unknown option: $1" >&2; exit 2 ;;
        *) archive="$1" ;;
    esac
    shift
done
[[ -d "$archive" ]] || { echo "usage: $0 <DaybookPhone.xcarchive> [--version X.Y.Z] [--build N]" >&2; exit 2; }

problem() { echo "check-ios-archive.sh: $*" >&2; failures=$(( failures + 1 )); }
ok() { echo "ok: $*"; }
plist_value() { plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }
plist_type() { plutil -type "$2" "$1" 2>/dev/null || true; }

app="$(find "$archive/Products/Applications" -maxdepth 1 -name '*.app' -print -quit)"
[[ -n "$app" ]] || { echo "check-ios-archive.sh: no app in $archive/Products/Applications" >&2; exit 1; }
info="$app/Info.plist"

encryption_type="$(plist_type "$info" ITSAppUsesNonExemptEncryption)"
encryption="$(plist_value "$info" ITSAppUsesNonExemptEncryption)"
if [[ "$encryption_type" == bool && "$encryption" == false ]]; then
    ok "ITSAppUsesNonExemptEncryption = false (exempt encryption only; the owner's decision)"
elif [[ -z "$encryption_type" ]]; then
    problem "Info.plist has no ITSAppUsesNonExemptEncryption. TestFlight would hold the build for the export compliance question. The owner's answer is false: keep ITSAppUsesNonExemptEncryption: false in Apps/iOS/project.yml (docs/release.md, Export compliance)."
else
    problem "ITSAppUsesNonExemptEncryption is $encryption ($encryption_type), not the boolean false the owner decided on. Changing that answer needs encryption documentation in App Store Connect first (docs/release.md)."
fi

families="$(plutil -extract UIDeviceFamily json -o - "$info" 2>/dev/null || true)"
if [[ "$families" == "[1]" ]]; then
    ok "UIDeviceFamily = [1] (iPhone only)"
else
    problem "UIDeviceFamily is ${families:-missing}, not [1]. An app that runs on iPad must list all four orientations for multitasking, and App Store Connect rejects the upload otherwise. Keep TARGETED_DEVICE_FAMILY: \"1\" on every target in Apps/iOS/project.yml (XcodeGen's presets set \"1,2\")."
fi

# App Intent metadata (the app's and every extension's): only the people-facing strings, so the
# com.apple.link.* protocol identifiers don't count.
intent_files=()
while IFS= read -r file; do intent_files+=("$file"); done < <(find "$app" -path '*/Metadata.appintents/extract.actionsdata' -type f)
if (( ${#intent_files[@]} )); then
    command -v jq >/dev/null || { echo "check-ios-archive.sh: jq is required to check App Intent strings" >&2; exit 1; }
    named=""
    for file in "${intent_files[@]}"; do
        named+="$(jq -r '[paths(scalars) as $p
                | select(($p | last) == "key" or any($p[]; . == "phrases" or . == "shortTitle"))
                | getpath($p) | select(type == "string")
                | select(test("(?i)\\b(iphone|ipad|ipod|apple|siri)\\b"))] | unique | .[]' "$file")"$'\n'
    done
    named="$(printf '%s' "$named" | sed '/^$/d' | sort -u)"
    if [[ -z "$named" ]]; then
        ok "App Intent strings name no Apple product"
    else
        problem "App Intent strings name an Apple product, which App Store processing rejects (ITMS-90626, Invalid Siri Support): $(printf '%s' "$named" | paste -sd '|' -)"
    fi
fi

if [[ -n "$(plist_type "$info" CFBundleIcons)" || -n "$(plist_type "$info" CFBundleIconFiles)" ]]; then
    ok "app icon: $(plist_value "$info" CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName)"
else
    problem "the app has no app icon (no CFBundleIcons in Info.plist), and App Store Connect rejects uploads without one (ITMS-90713, ITMS-90022). Add an AppIcon to DaybookPhone/Resources/Assets.xcassets and set ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon in Apps/iOS/project.yml."
fi

check_bundle() {
    local bundle="$1" expected_id="$2" plist="$1/Info.plist" id short long
    id="$(plist_value "$plist" CFBundleIdentifier)"
    short="$(plist_value "$plist" CFBundleShortVersionString)"
    long="$(plist_value "$plist" CFBundleVersion)"
    if [[ -n "$expected_id" && "$id" != "$expected_id" ]]; then
        problem "$(basename "$bundle") has bundle ID '$id', expected $expected_id"
    fi
    if [[ -n "$version" && "$short" != "$version" ]]; then
        problem "$(basename "$bundle") has CFBundleShortVersionString '$short', expected $version"
    fi
    if [[ -n "$build" && "$long" != "$build" ]]; then
        problem "$(basename "$bundle") has CFBundleVersion '$long', expected $build"
    fi
    ok "$(basename "$bundle"): $id $short ($long)"
}

check_bundle "$app" local.daybook
extensions=0
while IFS= read -r appex; do
    [[ -n "$appex" ]] || continue
    extensions=$(( extensions + 1 ))
    case "$(basename "$appex")" in
        DaybookPhoneWidgets.appex) check_bundle "$appex" local.daybook.widgets ;;
        *) check_bundle "$appex" "" ;;
    esac
done < <(find "$app/PlugIns" "$app/Extensions" -maxdepth 1 -name '*.appex' 2>/dev/null)
(( extensions > 0 )) || problem "no app extensions in $(basename "$app"): the widget extension should be embedded"

if codesign --verify --strict "$app" >/dev/null 2>&1; then
    entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)"
    for needle in group.local.daybook "$container"; do
        if printf '%s' "$entitlements" | grep -q "<string>$needle</string>"; then
            ok "entitlement: $needle"
        else
            problem "the signed app lacks the $needle entitlement"
        fi
    done
    # Keychain groups: the app's own first (the default for items stored without a group), then the iPhone app's from
    # before the one bundle ID (its items stay readable), then the one the Mac app shares for library and cloud keys
    # (docs/icloud-sync.md, "Encryption"). Each carries the team prefix.
    groups="$(printf '%s' "$entitlements" | plutil -extract keychain-access-groups json -o - - 2>/dev/null || true)"
    pattern='^\["[A-Z0-9]{10}\.local\.daybook","[A-Z0-9]{10}\.local\.daybook\.phone","[A-Z0-9]{10}\.local\.daybook\.shared"\]$'
    if [[ "$groups" =~ $pattern ]]; then
        ok "keychain groups: $groups"
    else
        problem "keychain-access-groups is ${groups:-missing}, not [<team>.local.daybook, <team>.local.daybook.phone, <team>.local.daybook.shared] in that order. The provisioning profile must grant <team>.* (docs/release.md, Capabilities and entitlements)."
    fi
else
    echo "note: $(basename "$app") isn't signed; skipping the entitlement check"
fi

if (( failures )); then
    echo "check-ios-archive.sh: $failures problem(s) in $archive" >&2
    exit 1
fi
echo "check-ios-archive.sh: $archive is ready to export"
