#!/bin/bash
# Builds Daybook for Mac with Xcode and packages dist/Daybook.app and dist/Daybook-macOS-arm64.zip.
# Generates Apps/macOS/DaybookMac.xcodeproj from Apps/macOS/project.yml with XcodeGen first; the app
# target compiles Sources/Daybook and links the package's libraries.
#
#   scripts/build-app.sh                  Release: xcodebuild archive, then -exportArchive with the
#                                         developer-id method (Developer ID Application + its profile)
#   scripts/build-app.sh --debug          Debug build, signed with Apple Development (ad hoc without a team)
#   scripts/build-app.sh --ad-hoc         sign to run locally: no team, no profile, no iCloud entitlements;
#                                         the app runs and keeps sync off. Combine with --debug. Bundle ID
#                                         local.daybook.adhoc, so it never uses the app's container.
#   scripts/build-app.sh --sandbox        Release, signed: run in the App Sandbox (Daybook-Sandbox.entitlements)
#                                         and embed the container migration manifest, so the first launch MOVES
#                                         ~/Library/Application Support/Daybook (and the preferences) into
#                                         local.daybook's container, once and for good (docs/sandbox.md). Also
#                                         DAYBOOK_SANDBOX=1. Needs a team; refuses --debug and --ad-hoc. Without it
#                                         signed builds aren't sandboxed. Signed builds are local.daybook either way,
#                                         the iPhone app's bundle ID too.
#   scripts/build-app.sh --app-store      the Mac App Store and TestFlight build: --sandbox, exported with the
#                                         app-store-connect method to build/macOS/AppStore (a .pkg) instead of
#                                         Developer ID; nothing goes to dist/. Add --upload to send it to App Store
#                                         Connect, where it joins the iPhone app's record (docs/release.md,
#                                         "Mac on TestFlight").
#   scripts/build-app.sh --sandbox-rehearsal
#                                         ad hoc, bundle ID local.daybook.rehearsal (or
#                                         $DAYBOOK_REHEARSAL_BUNDLE_ID), with a manifest that moves
#                                         ~/Library/Application Support/Daybook Rehearsal into its container on
#                                         first launch: the migration rehearsal (docs/sandbox.md)
#   scripts/build-app.sh --allow-provisioning-updates
#                                         let Xcode register what signing needs on the Apple Developer
#                                         account: the local.daybook identifier with iCloud and its
#                                         container, this Mac, a development profile, and the Developer ID
#                                         profile. For the account owner, once (README.md, "First-time
#                                         provisioning"). Without it the script never changes the account.
#   scripts/build-app.sh --generate-only  just regenerate the Xcode project
#   scripts/build-app.sh --resolve-only   regenerate it and fetch the packages at Package.resolved's versions
#   scripts/build-app.sh --archive-only   Release: generate, resolve, and archive, then stop
#   scripts/build-app.sh --export-only    Release: export the archive --archive-only made, then package dist/.
#                                         The release pipeline splits the two so that each step gets only
#                                         the secrets it needs (docs/release.md, "Secrets on the runner").
#
# Xcode resolves packages only to the versions in Package.resolved (-onlyUsePackageVersionsFromResolvedFile),
# and the script fails if resolving would change that file.
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
#   DAYBOOK_SANDBOX           1 (or YES, true) is --sandbox; 0, NO, false, or unset leave signed builds
#                             unsandboxed
#   DAYBOOK_REHEARSAL_BUNDLE_ID
#                             --sandbox-rehearsal's bundle ID, local.daybook.rehearsal…: a container can't be
#                             fully removed, so each rehearsal from scratch needs a new one
#   XCODEGEN                  path to xcodegen (default: from PATH, then /opt/homebrew/bin)
#   DAYBOOK_ASC_KEY_PATH, DAYBOOK_ASC_KEY_ID, DAYBOOK_ASC_ISSUER_ID
#                             an App Store Connect API key, for the release pipeline only
#                             (.github/workflows/release.yml, docs/release.md). With all three set, a signed
#                             build authenticates with the key and passes -allowProvisioningUpdates (never
#                             device registration), so Xcode's cloud-managed signing supplies the
#                             Developer ID certificate and profile; a Developer ID identity already in a
#                             keychain is used instead when there is one. Refused outside release.yml on
#                             GitHub Actions (AGENTS.md).
#   DAYBOOK_DEVELOPER_ID_PROFILE
#                             UUID of an installed Developer ID profile for the archived app's bundle ID
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
sandbox=0
case "${DAYBOOK_SANDBOX:-}" in
    1|YES|yes|true) sandbox=1 ;;
    ""|0|NO|no|false) ;;
    *) echo "DAYBOOK_SANDBOX is 1 or 0, not ${DAYBOOK_SANDBOX}." >&2; exit 2 ;;
esac
app_store=0
upload=0
generate_only=0
resolve_only=0
archive_only=0
export_only=0
provisioning=()
version_settings=()

usage() { sed -n '2,/^set -euo/p' "$script_path" | sed '$d' | sed -E 's/^# ?//'; }

while (( $# )); do
    case "$1" in
        --debug) configuration=Debug ;;
        --ad-hoc) signing=local ;;
        --sandbox-rehearsal) signing=rehearsal ;;
        --sandbox) sandbox=1 ;;
        --app-store) app_store=1; sandbox=1 ;;
        --upload) upload=1 ;;
        --allow-provisioning-updates) provisioning=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration) ;;
        --generate-only) generate_only=1 ;;
        --resolve-only) resolve_only=1 ;;
        --archive-only) archive_only=1 ;;
        --export-only) export_only=1 ;;
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
# The key brings -allowProvisioningUpdates, which only the release pipeline may pass (AGENTS.md).
if (( asc_set == 3 )) && [[ "${GITHUB_ACTIONS:-}" != true || "${GITHUB_WORKFLOW_REF:-}" != */.github/workflows/release.yml@* ]]; then
    echo "The App Store Connect API key is for the release pipeline only (.github/workflows/release.yml), because it" >&2
    echo "passes -allowProvisioningUpdates. Use your Xcode account and existing profiles instead (AGENTS.md)." >&2
    exit 2
fi

if (( archive_only + export_only + resolve_only + generate_only > 1 )); then
    echo "Choose one of --generate-only, --resolve-only, --archive-only, and --export-only." >&2
    exit 2
fi
if (( archive_only || export_only )) && [[ "$configuration" == Debug ]]; then
    echo "--archive-only and --export-only are for Release builds; drop --debug." >&2
    exit 2
fi
if (( upload && ! app_store )); then
    echo "--upload sends the App Store build to App Store Connect; add --app-store." >&2
    exit 2
fi

pinned=(-onlyUsePackageVersionsFromResolvedFile)
if (( ! export_only )); then
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

    # Fetch the packages, held to Package.resolved, and make sure Xcode didn't pick other versions.
    xcodebuild -resolvePackageDependencies -project "$project" -scheme Daybook \
        -clonedSourcePackagesDirPath "$packages_dir" "${pinned[@]}"
    if ! cmp -s "$repo_dir/Package.resolved" "$resolved_dir/Package.resolved"; then
        echo "Xcode resolved other package versions than Package.resolved pins:" >&2
        diff -u "$repo_dir/Package.resolved" "$resolved_dir/Package.resolved" >&2 || true
        exit 1
    fi
    if (( resolve_only )); then exit 0; fi
fi

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
if [[ "$signing" == local || "$signing" == rehearsal ]]; then
    if (( ${#provisioning[@]} )); then
        echo "--allow-provisioning-updates needs DAYBOOK_TEAM_ID and can't be combined with --ad-hoc or --sandbox-rehearsal." >&2
        exit 2
    fi
    echo "Signing ad hoc: no team, so this build has no iCloud entitlements and keeps sync off."
fi
if (( sandbox )); then
    # Only a signed Release build may run sandboxed as local.daybook: its first launch creates the app's container
    # and moves the real library into it, once. A development build must never be the one that does (docs/sandbox.md).
    if [[ "$signing" != signed ]]; then
        echo "--sandbox and --app-store are for signed builds (DAYBOOK_TEAM_ID). Ad hoc builds are always sandboxed, as local.daybook.adhoc." >&2
        exit 2
    fi
    if [[ "$configuration" == Debug ]]; then
        echo "--sandbox and --app-store are for Release builds: a Debug build must never create the app's container." >&2
        exit 2
    fi
    echo "App Sandbox: this build's first launch moves ~/Library/Application Support/Daybook into its container (docs/sandbox.md)."
fi
rehearsal_id="${DAYBOOK_REHEARSAL_BUNDLE_ID:-local.daybook.rehearsal}"
if [[ "$signing" == rehearsal ]]; then
    if [[ ! "$rehearsal_id" =~ ^local\.daybook\.rehearsal[A-Za-z0-9.-]*$ ]]; then
        echo "DAYBOOK_REHEARSAL_BUNDLE_ID must start with local.daybook.rehearsal, not $rehearsal_id." >&2
        exit 2
    fi
    echo "Migration rehearsal: bundle ID $rehearsal_id moves ~/Library/Application Support/Daybook Rehearsal into its container."
fi

# ARCHS on the command line reaches the package targets too: Apple silicon only, as before.
settings=(ARCHS=arm64 "DAYBOOK_SIGNING=$signing" "DAYBOOK_SOURCE_PACKAGES=$packages_dir")
if [[ "$signing" == rehearsal ]]; then settings+=("DAYBOOK_BUNDLE_ID_rehearsal=$rehearsal_id"); fi
if (( sandbox )); then settings+=(DAYBOOK_SANDBOX=YES); else settings+=(DAYBOOK_SANDBOX=NO); fi
if [[ -n "$team" ]]; then settings+=("DAYBOOK_TEAM_ID=$team"); fi
if [[ -n "${DAYBOOK_ICLOUD_CONTAINER:-}" ]]; then settings+=("DAYBOOK_ICLOUD_CONTAINER=$DAYBOOK_ICLOUD_CONTAINER"); fi
settings+=(${version_settings[@]+"${version_settings[@]}"})
common=(-project "$project" -scheme Daybook -configuration "$configuration"
        -derivedDataPath "$derived_dir" -clonedSourcePackagesDirPath "$packages_dir" "${pinned[@]}")

mkdir -p "$work_dir" "$dist_dir"
if [[ "$configuration" == Debug ]]; then
    xcodebuild "${common[@]}" -destination 'platform=macOS,arch=arm64' ${provisioning[@]+"${provisioning[@]}"} build "${settings[@]}"
    built="$derived_dir/Build/Products/Debug/Daybook.app"
else
    archive="$work_dir/Daybook.xcarchive"
    if (( export_only )); then
        [[ -d "$archive" ]] || { echo "No archive at $archive: run --archive-only first." >&2; exit 1; }
    else
        /bin/rm -rf "${archive:?}"
        xcodebuild "${common[@]}" -destination 'generic/platform=macOS' -archivePath "$archive" \
            ${provisioning[@]+"${provisioning[@]}"} archive "${settings[@]}"
    fi
    if (( archive_only )); then
        echo "Archive: $archive"
        exit 0
    fi
    if (( app_store )); then
        # The Mac App Store and TestFlight: re-signed for distribution (Apple Distribution, and the installer certificate
        # for the .pkg) with the App Store profile. Xcode picks them, or with the API key's -allowProvisioningUpdates
        # (release.yml only) makes them. The App Store sets the iCloud and push environments to Production itself.
        export_dir="$work_dir/AppStore"
        export_options="$work_dir/ExportOptions.plist"
        /bin/rm -rf "${export_dir:?}"
        /bin/rm -f "${export_options:?}"
        plutil -create xml1 "$export_options"
        plutil -insert method -string app-store-connect "$export_options"
        if (( upload )); then destination="upload"; else destination="export"; fi
        plutil -insert destination -string "$destination" "$export_options"
        plutil -insert signingStyle -string automatic "$export_options"
        plutil -insert teamID -string "$team" "$export_options"
        plutil -insert uploadSymbols -bool YES "$export_options"
        # The pipeline sets the version and build number; App Store Connect must not change them.
        plutil -insert manageAppVersionAndBuildNumber -bool NO "$export_options"
        xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
            -exportOptionsPlist "$export_options" ${provisioning[@]+"${provisioning[@]}"}
        if (( upload )); then echo "Uploaded $archive to App Store Connect."; else echo "App Store export: $export_dir"; fi
        exit 0
    fi
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
            # The archived app's bundle ID (local.daybook), which names the profile.
            bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$archive/Products/Applications/Daybook.app/Contents/Info.plist")"
            plutil -insert "provisioningProfiles.${bundle_id//./\\.}" -string "$DAYBOOK_DEVELOPER_ID_PROFILE" "$export_options"
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
