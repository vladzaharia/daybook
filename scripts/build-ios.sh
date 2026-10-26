#!/bin/bash
# Builds Daybook for iPhone (Apps/iOS). Generates the Xcode project from Apps/iOS/project.yml with
# XcodeGen, then builds with xcodebuild. It never installs anything on a device.
#
#   scripts/build-ios.sh                    generate, then build for the iOS Simulator (no team needed)
#   scripts/build-ios.sh --test             ... and run the unit tests on a simulator
#   scripts/build-ios.sh --device           build for a physical iPhone with automatic signing;
#                                           needs DAYBOOK_TEAM_ID (or Apps/iOS/Config/Signing.local.xcconfig)
#                                           and profiles that already exist: the script never registers
#                                           identifiers, the app group, or the iCloud container
#                                           (no -allowProvisioningUpdates). Do that once, deliberately,
#                                           in Xcode's Signing & Capabilities.
#   scripts/build-ios.sh --device --no-sign compile for a device without signing (a CI check)
#   scripts/build-ios.sh --generate-only    just regenerate Apps/iOS/Daybook.xcodeproj
#   scripts/build-ios.sh --resolve          regenerate it and fetch the packages at Package.resolved's versions
#   scripts/build-ios.sh --archive          xcodebuild archive (Release) to Apps/iOS/build/DaybookPhone.xcarchive,
#                                           with the widget extension; signed like --device. Add --no-sign
#                                           for an unsigned archive (a local or CI check).
#   scripts/build-ios.sh --archive --export upload
#                                           ... then -exportArchive with the app-store-connect method:
#                                           `upload` sends it to App Store Connect (TestFlight), `export`
#                                           writes the .ipa to Apps/iOS/build/Export. --export alone
#                                           exports an existing --archive-path.
#
# Options:
#   --simulator <name or UDID>   simulator for --test (default: an iPhone Duo, else the first iPhone)
#   --configuration <Debug|Release>   default Debug (Release for --archive)
#   --marketing-version <X.Y.Z>  MARKETING_VERSION (CFBundleShortVersionString of app and extension)
#   --build-number <N>           CURRENT_PROJECT_VERSION (CFBundleVersion of app and extension)
#   --archive-path <path>        default Apps/iOS/build/DaybookPhone.xcarchive
#   --test-arg <argument>        pass an argument to the `xcodebuild test` invocation only (repeatable),
#                                e.g. --test-arg -only-testing:DaybookPhoneTests/ShellTests
#
# Xcode resolves packages only to the versions in Package.resolved (-onlyUsePackageVersionsFromResolvedFile),
# and every build fails if resolving would change that file.
#
# Environment:
#   DAYBOOK_TEAM_ID              Apple Developer team for device builds
#   DAYBOOK_ICLOUD_CONTAINER     iCloud container for sync (default iCloud.local.daybook)
#   DAYBOOK_IOS_DERIVED_DATA     derived data folder (default Apps/iOS/build/DerivedData)
#   XCODEGEN                     path to xcodegen (default: from PATH, then /opt/homebrew/bin)
#   DAYBOOK_ASC_KEY_PATH, DAYBOOK_ASC_KEY_ID, DAYBOOK_ASC_ISSUER_ID
#                                an App Store Connect API key, for the release pipeline only
#                                (.github/workflows/release.yml, docs/release.md). With all three set,
#                                --archive and --export authenticate with the key and pass
#                                -allowProvisioningUpdates, so Xcode's cloud-managed signing supplies the
#                                certificates and profiles. Nothing else in this script uses them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Apps/iOS"
PROJECT="$APP/Daybook.xcodeproj"
DERIVED="${DAYBOOK_IOS_DERIVED_DATA:-$APP/build/DerivedData}"
CONFIGURATION=""
MODE=simulator
RUN_TESTS=0
SIGN=1
SIMULATOR=""
EXPORT=""
ARCHIVE_PATH="$APP/build/DaybookPhone.xcarchive"
EXPORT_PATH="$APP/build/Export"
VERSION_SETTINGS=()
TEST_ARGS=()

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) MODE=device ;;
        --no-sign) SIGN=0 ;;
        --test) RUN_TESTS=1 ;;
        --generate-only) MODE=generate ;;
        --resolve) MODE=resolve ;;
        --archive) MODE=archive ;;
        --export) EXPORT="$2"; shift ;;
        --archive-path) ARCHIVE_PATH="$2"; shift ;;
        --simulator) SIMULATOR="$2"; shift ;;
        --configuration) CONFIGURATION="$2"; shift ;;
        --marketing-version) VERSION_SETTINGS+=("MARKETING_VERSION=$2"); shift ;;
        --build-number) VERSION_SETTINGS+=("CURRENT_PROJECT_VERSION=$2"); shift ;;
        --test-arg) TEST_ARGS+=("$2"); shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [[ -n "$EXPORT" && "$EXPORT" != upload && "$EXPORT" != export ]]; then
    echo "--export takes upload or export" >&2
    exit 2
fi
if [[ -n "$EXPORT" && "$MODE" == simulator && "$RUN_TESTS" == 0 ]]; then
    MODE="export"
fi
if [[ -n "$EXPORT" && "$MODE" != archive && "$MODE" != export ]]; then
    echo "--export goes with --archive, or alone to export an existing --archive-path" >&2
    exit 2
fi
if [[ -z "$CONFIGURATION" ]]; then
    if [[ "$MODE" == archive || "$MODE" == export ]]; then CONFIGURATION=Release; else CONFIGURATION=Debug; fi
fi

# The App Store Connect API key, all or nothing (release pipeline only).
AUTH=()
ASC_SET=0
for name in DAYBOOK_ASC_KEY_PATH DAYBOOK_ASC_KEY_ID DAYBOOK_ASC_ISSUER_ID; do
    if [[ -n "${!name:-}" ]]; then ASC_SET=$(( ASC_SET + 1 )); fi
done
if (( ASC_SET == 3 )); then
    AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$DAYBOOK_ASC_KEY_PATH"
          -authenticationKeyID "$DAYBOOK_ASC_KEY_ID" -authenticationKeyIssuerID "$DAYBOOK_ASC_ISSUER_ID")
elif (( ASC_SET > 0 )); then
    echo "Set all of DAYBOOK_ASC_KEY_PATH, DAYBOOK_ASC_KEY_ID, and DAYBOOK_ASC_ISSUER_ID, or none." >&2
    exit 2
fi

XCODEGEN="${XCODEGEN:-$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)}"
if [[ "$MODE" != export && ! -x "$XCODEGEN" ]]; then
    echo "XcodeGen is required: brew install xcodegen" >&2
    exit 1
fi

if [[ "$MODE" != export ]]; then
    echo "Generating $PROJECT"
    "$XCODEGEN" generate --spec "$APP/project.yml" --project "$APP" --quiet
    # Pin the package graph to the repository's resolved versions, as `swift build` does.
    RESOLVED_DIR="$PROJECT/project.xcworkspace/xcshareddata/swiftpm"
    mkdir -p "$RESOLVED_DIR"
    cp "$ROOT/Package.resolved" "$RESOLVED_DIR/Package.resolved"
fi

[[ "$MODE" == generate ]] && exit 0

PINNED=(-onlyUsePackageVersionsFromResolvedFile)
if [[ "$MODE" != export ]]; then
    # Fetch the packages, held to Package.resolved, and make sure Xcode didn't pick other versions.
    xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme DaybookPhone -derivedDataPath "$DERIVED" "${PINNED[@]}"
    if ! cmp -s "$ROOT/Package.resolved" "$RESOLVED_DIR/Package.resolved"; then
        echo "Xcode resolved other package versions than Package.resolved pins:" >&2
        diff -u "$ROOT/Package.resolved" "$RESOLVED_DIR/Package.resolved" >&2 || true
        exit 1
    fi
fi
[[ "$MODE" == resolve ]] && exit 0

COMMON=(-project "$PROJECT" -scheme DaybookPhone -configuration "$CONFIGURATION" -derivedDataPath "$DERIVED" "${PINNED[@]}")
# The xcconfig's default container yields to the environment (command-line settings win).
[[ -n "${DAYBOOK_ICLOUD_CONTAINER:-}" ]] && COMMON+=("DAYBOOK_ICLOUD_CONTAINER=$DAYBOOK_ICLOUD_CONTAINER")
(( ${#VERSION_SETTINGS[@]} )) && COMMON+=("${VERSION_SETTINGS[@]}")

require_team() {
    if [[ -z "${DAYBOOK_TEAM_ID:-}" && ! -f "$APP/Config/Signing.local.xcconfig" ]]; then
        echo "Set DAYBOOK_TEAM_ID (or create Apps/iOS/Config/Signing.local.xcconfig) for a signed $1," >&2
        echo "or pass --no-sign to only compile." >&2
        exit 1
    fi
}

if [[ "$MODE" == device ]]; then
    if [[ "$SIGN" == 1 ]]; then
        require_team "device build"
        # No -allowProvisioningUpdates: registering identifiers and capabilities on the developer
        # account is a separate step the account owner takes in Xcode.
        xcodebuild "${COMMON[@]}" -destination 'generic/platform=iOS' build
    else
        xcodebuild "${COMMON[@]}" -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
    fi
    echo "Built $DERIVED/Build/Products/$CONFIGURATION-iphoneos/DaybookPhone.app (not installed)."
    exit 0
fi

if [[ "$MODE" == archive ]]; then
    rm -rf "${ARCHIVE_PATH:?}"
    if [[ "$SIGN" == 1 ]]; then
        require_team "archive"
        TEAM_SETTINGS=()
        [[ -n "${DAYBOOK_TEAM_ID:-}" ]] && TEAM_SETTINGS=("DAYBOOK_TEAM_ID=$DAYBOOK_TEAM_ID")
        # Without the API key this uses only profiles that already exist, like --device. With it
        # (release.yml), Xcode may create the development certificate and profiles it needs.
        xcodebuild "${COMMON[@]}" -destination 'generic/platform=iOS' -archivePath "$ARCHIVE_PATH" \
            ${AUTH[@]+"${AUTH[@]}"} archive ${TEAM_SETTINGS[@]+"${TEAM_SETTINGS[@]}"}
    else
        xcodebuild "${COMMON[@]}" -destination 'generic/platform=iOS' -archivePath "$ARCHIVE_PATH" \
            archive CODE_SIGNING_ALLOWED=NO
    fi
    echo "Archived $ARCHIVE_PATH"
    [[ -z "$EXPORT" ]] && exit 0
    MODE="export"
fi

if [[ "$MODE" == export ]]; then
    if [[ "$SIGN" == 0 ]]; then
        echo "--export needs a signed archive; drop --no-sign." >&2
        exit 2
    fi
    [[ -d "$ARCHIVE_PATH" ]] || { echo "No archive at $ARCHIVE_PATH" >&2; exit 1; }
    TEAM="${DAYBOOK_TEAM_ID:-}"
    if [[ -z "$TEAM" && -f "$APP/Config/Signing.local.xcconfig" ]]; then
        TEAM="$(sed -nE 's/^[[:space:]]*DAYBOOK_TEAM_ID[[:space:]]*=[[:space:]]*([A-Z0-9]+).*/\1/p' "$APP/Config/Signing.local.xcconfig" | tail -1)"
    fi
    [[ -n "$TEAM" ]] || { echo "--export needs DAYBOOK_TEAM_ID" >&2; exit 1; }
    OPTIONS="$APP/build/ExportOptions.plist"
    mkdir -p "$APP/build"
    rm -f "${OPTIONS:?}"
    plutil -create xml1 "$OPTIONS"
    plutil -insert method -string app-store-connect "$OPTIONS"
    plutil -insert destination -string "$EXPORT" "$OPTIONS"
    plutil -insert signingStyle -string automatic "$OPTIONS"
    plutil -insert teamID -string "$TEAM" "$OPTIONS"
    plutil -insert uploadSymbols -bool YES "$OPTIONS"
    # The pipeline sets the version and build number; App Store Connect must not change them.
    plutil -insert manageAppVersionAndBuildNumber -bool NO "$OPTIONS"
    # An upload that fails on the network (a timeout, a dropped or refused connection) is tried again,
    # up to three times; anything else, such as Apple rejecting the build, fails at once. The wait
    # between tries is 30 s, then 60 s (DAYBOOK_UPLOAD_RETRY_DELAY scales it; the tests set 0).
    LOG="$APP/build/export.log"
    for (( attempt = 1; ; attempt++ )); do
        rm -rf "${EXPORT_PATH:?}"
        if xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_PATH" \
            -exportOptionsPlist "$OPTIONS" ${AUTH[@]+"${AUTH[@]}"} 2>&1 | tee "$LOG"; then
            break
        fi
        if [[ "$EXPORT" != upload || $attempt -ge 3 ]] \
            || ! grep -q -i -E 'request timed out|network connection was lost|could not connect|not connected to the internet|NSURLErrorDomain|ENOTFOUND|-100[1459]' "$LOG"; then
            exit 70
        fi
        echo "::warning title=Upload retried::the upload failed on the network (attempt $attempt of 3); trying again"
        sleep $(( attempt * ${DAYBOOK_UPLOAD_RETRY_DELAY:-30} ))
    done
    if [[ "$EXPORT" == upload ]]; then
        echo "Uploaded $ARCHIVE_PATH to App Store Connect."
    else
        echo "Exported $EXPORT_PATH"
    fi
    exit 0
fi

xcodebuild "${COMMON[@]}" -destination 'generic/platform=iOS Simulator' build
echo "Built $DERIVED/Build/Products/$CONFIGURATION-iphonesimulator/DaybookPhone.app"

if [[ "$RUN_TESTS" == 1 ]]; then
    if [[ -z "$SIMULATOR" ]]; then
        SIMULATOR=$(xcrun simctl list devices available | grep -E "^\s+iPhone Duo" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
        [[ -z "$SIMULATOR" ]] && SIMULATOR=$(xcrun simctl list devices available | grep -E "^\s+iPhone" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
    fi
    if [[ -z "$SIMULATOR" ]]; then
        echo "No iPhone simulator is available for --test." >&2
        exit 1
    fi
    if [[ "$SIMULATOR" =~ ^[0-9A-F-]{36}$ ]]; then DESTINATION="id=$SIMULATOR"; else DESTINATION="platform=iOS Simulator,name=$SIMULATOR"; fi
    xcodebuild "${COMMON[@]}" -destination "$DESTINATION" test ${TEST_ARGS[@]+"${TEST_ARGS[@]}"}
fi
