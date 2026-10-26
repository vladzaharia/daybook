#!/bin/bash
# Builds Daybook for Mac with Xcode and packages dist/Daybook.app and dist/Daybook-macOS-arm64.zip.
# Generates Apps/macOS/DaybookMac.xcodeproj from Apps/macOS/project.yml with XcodeGen first; the app
# target compiles Sources/Daybook and links the package's libraries.
#
#   scripts/build-app.sh                  Release: xcodebuild archive, then -exportArchive with the
#                                         developer-id method (Developer ID Application + its profile)
#   scripts/build-app.sh --debug          Debug build, signed with Apple Development (ad hoc without a team)
#   scripts/build-app.sh --ad-hoc         sign to run locally: no team, no profile, no iCloud entitlements;
#                                         the app runs and keeps sync off. Combine with --debug.
#   scripts/build-app.sh --allow-provisioning-updates
#                                         let Xcode register what signing needs on the Apple Developer
#                                         account: the local.daybook.app identifier with iCloud and its
#                                         container, this Mac, a development profile, and the Developer ID
#                                         profile. For the account owner, once (README.md, "First-time
#                                         provisioning"). Without it the script never changes the account.
#   scripts/build-app.sh --generate-only  just regenerate the Xcode project
#   scripts/build-app.sh --marketing-version 1.4.0 --build-number 1057
#                                         set MARKETING_VERSION and CURRENT_PROJECT_VERSION (Info.plist's
#                                         CFBundleShortVersionString and CFBundleVersion); the release
#                                         pipeline derives them from the tag (scripts/ci/version.sh)
#
# Environment:
#   DAYBOOK_TEAM_ID           Apple Developer team (or Apps/macOS/Config/Signing.local.xcconfig).
#                             Without one, the build is ad hoc.
#   DAYBOOK_ICLOUD_CONTAINER  iCloud container for sync (default iCloud.local.daybook)
#   DAYBOOK_NOTARY_PROFILE    notarytool keychain profile: notarize and staple the Developer ID export
#   DAYBOOK_MAC_DERIVED_DATA  derived data (default build/macOS/DerivedData)
#   XCODEGEN                  path to xcodegen (default: from PATH, then /opt/homebrew/bin)
#   DAYBOOK_ASC_KEY_PATH, DAYBOOK_ASC_KEY_ID, DAYBOOK_ASC_ISSUER_ID
#                             an App Store Connect API key, for the release pipeline only
#                             (.github/workflows/release.yml, docs/release.md). With all three set, a signed
#                             build authenticates with the key and passes -allowProvisioningUpdates (never
#                             device registration), so Xcode's cloud-managed signing supplies the
#                             Developer ID certificate and profile; a Developer ID identity already in a
#                             keychain is used instead when there is one.
#   DAYBOOK_DEVELOPER_ID_PROFILE
#                             UUID of an installed Developer ID profile for local.daybook.app
#                             (scripts/ci/asc-profile.sh). The export then signs manually with the
#                             keychain's Developer ID Application identity and that profile, and doesn't
#                             ask for cloud signing, which a team API key can't use for Developer ID.
set -euo pipefail

script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
repo_dir="$(cd "$(dirname "$script_path")/.." && pwd)"
spec_dir="$repo_dir/Apps/macOS"
project="$spec_dir/DaybookMac.xcodeproj"
work_dir="$repo_dir/build/macOS"
derived_dir="${DAYBOOK_MAC_DERIVED_DATA:-$work_dir/DerivedData}"
packages_dir="$work_dir/SourcePackages"
dist_dir="$repo_dir/dist"
configuration=Release
signing=""
generate_only=0
provisioning=()
version_settings=()

usage() { sed -n '2,/^set -euo/p' "$script_path" | sed '$d' | sed -E 's/^# ?//'; }

while (( $# )); do
    case "$1" in
        --debug) configuration=Debug ;;
        --ad-hoc) signing=local ;;
        --allow-provisioning-updates) provisioning=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration) ;;
        --generate-only) generate_only=1 ;;
        --marketing-version) version_settings+=("MARKETING_VERSION=${2-}"); shift ;;
        --build-number) version_settings+=("CURRENT_PROJECT_VERSION=${2-}"); shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# The App Store Connect API key (release pipeline): all three variables or none.
asc_set=0
for name in DAYBOOK_ASC_KEY_PATH DAYBOOK_ASC_KEY_ID DAYBOOK_ASC_ISSUER_ID; do
    if [[ -n "${!name:-}" ]]; then asc_set=$(( asc_set + 1 )); fi
done
if (( asc_set > 0 && asc_set < 3 )); then
    echo "Set all of DAYBOOK_ASC_KEY_PATH, DAYBOOK_ASC_KEY_ID, and DAYBOOK_ASC_ISSUER_ID, or none." >&2
    exit 2
fi

xcodegen_path="${XCODEGEN:-$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)}"
if [[ ! -x "$xcodegen_path" ]]; then
    echo "XcodeGen is required: brew install xcodegen" >&2
    exit 1
fi
if ! xcrun metal --version >/dev/null 2>&1; then
    echo "The Xcode Metal compiler is required. Run: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
fi

echo "Generating $project"
"$xcodegen_path" generate --spec "$spec_dir/project.yml" --project "$spec_dir" --quiet
# Pin the package graph to the repository's resolved versions, as `swift build` does.
resolved_dir="$project/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$resolved_dir"
/bin/cp -f "$repo_dir/Package.resolved" "$resolved_dir/Package.resolved"
if (( generate_only )); then exit 0; fi

team="${DAYBOOK_TEAM_ID:-}"
local_config="$spec_dir/Config/Signing.local.xcconfig"
if [[ -z "$team" && -f "$local_config" ]]; then
    team="$(sed -nE 's/^[[:space:]]*DAYBOOK_TEAM_ID[[:space:]]*=[[:space:]]*([A-Z0-9]+).*/\1/p' "$local_config" | tail -1)"
fi
if [[ -z "$signing" ]]; then
    if [[ -n "$team" ]]; then signing=signed; else signing=local; fi
fi
if (( asc_set == 3 )) && [[ "$signing" == signed ]]; then
    if (( ${#provisioning[@]} == 0 )); then provisioning=(-allowProvisioningUpdates); fi
    provisioning+=(-authenticationKeyPath "$DAYBOOK_ASC_KEY_PATH" -authenticationKeyID "$DAYBOOK_ASC_KEY_ID"
                   -authenticationKeyIssuerID "$DAYBOOK_ASC_ISSUER_ID")
fi
if [[ "$signing" == local ]]; then
    if (( ${#provisioning[@]} )); then
        echo "--allow-provisioning-updates needs DAYBOOK_TEAM_ID and can't be combined with --ad-hoc." >&2
        exit 2
    fi
    echo "Signing ad hoc: no team, so this build has no iCloud entitlements and keeps sync off."
fi

# ARCHS on the command line reaches the package targets too: Apple silicon only, as before.
settings=(ARCHS=arm64 "DAYBOOK_SIGNING=$signing" "DAYBOOK_SOURCE_PACKAGES=$packages_dir")
if [[ -n "$team" ]]; then settings+=("DAYBOOK_TEAM_ID=$team"); fi
if [[ -n "${DAYBOOK_ICLOUD_CONTAINER:-}" ]]; then settings+=("DAYBOOK_ICLOUD_CONTAINER=$DAYBOOK_ICLOUD_CONTAINER"); fi
settings+=(${version_settings[@]+"${version_settings[@]}"})
common=(-project "$project" -scheme Daybook -configuration "$configuration"
        -derivedDataPath "$derived_dir" -clonedSourcePackagesDirPath "$packages_dir")

mkdir -p "$work_dir" "$dist_dir"
if [[ "$configuration" == Debug ]]; then
    xcodebuild "${common[@]}" -destination 'platform=macOS,arch=arm64' ${provisioning[@]+"${provisioning[@]}"} build "${settings[@]}"
    built="$derived_dir/Build/Products/Debug/Daybook.app"
else
    archive="$work_dir/Daybook.xcarchive"
    /bin/rm -rf "${archive:?}"
    xcodebuild "${common[@]}" -destination 'generic/platform=macOS' -archivePath "$archive" \
        ${provisioning[@]+"${provisioning[@]}"} archive "${settings[@]}"
    if [[ "$signing" == signed ]]; then
        # Re-sign for distribution outside the App Store with Developer ID and its provisioning profile,
        # which carries the iCloud container. Xcode picks (or, with -allowProvisioningUpdates, creates) it.
        export_dir="$work_dir/Export"
        export_options="$work_dir/ExportOptions.plist"
        /bin/rm -rf "${export_dir:?}"
        /bin/rm -f "${export_options:?}"
        plutil -create xml1 "$export_options"
        plutil -insert method -string developer-id "$export_options"
        plutil -insert teamID -string "$team" "$export_options"
        plutil -insert destination -string export "$export_options"
        # Outside the App Store, an app with iCloud containers must name the container environment;
        # a release uses Production.
        plutil -insert iCloudContainerEnvironment -string Production "$export_options"
        export_provisioning=(${provisioning[@]+"${provisioning[@]}"})
        if [[ -n "${DAYBOOK_DEVELOPER_ID_PROFILE:-}" ]]; then
            # Manual: the Developer ID identity in a keychain and the profile scripts/ci/asc-profile.sh
            # installed. With a team API key, automatic export insists on cloud-managed Developer ID
            # signing, which only the Account Holder may use, so the key stays out of the export.
            plutil -insert signingStyle -string manual "$export_options"
            plutil -insert signingCertificate -string "Developer ID Application" "$export_options"
            plutil -insert provisioningProfiles -dictionary "$export_options"
            plutil -insert "provisioningProfiles.local\\.daybook\\.app" -string "$DAYBOOK_DEVELOPER_ID_PROFILE" "$export_options"
            export_provisioning=()
        else
            plutil -insert signingStyle -string automatic "$export_options"
        fi
        xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
            -exportOptionsPlist "$export_options" ${export_provisioning[@]+"${export_provisioning[@]}"}
        built="$export_dir/Daybook.app"
    else
        built="$archive/Products/Applications/Daybook.app"
    fi
fi

app_dir="$dist_dir/Daybook.app"
zip_path="$dist_dir/Daybook-macOS-arm64.zip"
# Resolved package licenses can be read-only; make the previous bundle removable.
if [[ -d "$app_dir" ]]; then chmod -R u+w "$app_dir"; fi
/bin/rm -rf "${app_dir:?}"
ditto "$built" "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"
/bin/rm -f "${zip_path:?}"
ditto -c -k --keepParent "$app_dir" "$zip_path"

if [[ -n "${DAYBOOK_NOTARY_PROFILE:-}" ]]; then
    if [[ "$configuration" != Release || "$signing" != signed ]]; then
        echo "Notarization needs the Release Developer ID export: DAYBOOK_TEAM_ID set, without --debug or --ad-hoc." >&2
        exit 1
    fi
    xcrun notarytool submit "$zip_path" --keychain-profile "$DAYBOOK_NOTARY_PROFILE" --wait
    xcrun stapler staple "$app_dir"
    /bin/rm -f "${zip_path:?}"
    ditto -c -k --keepParent "$app_dir" "$zip_path"
fi

echo "App: $app_dir"
echo "Archive: $zip_path"
codesign -dv "$app_dir" 2>&1 | grep -E '^(Authority|TeamIdentifier|Signature)=' | head -3 || true
