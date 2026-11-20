#!/bin/bash
# Builds Daybook for iPhone (Apps/iOS). Generates the Xcode project from Apps/iOS/project.yml with
# XcodeGen, then builds with xcodebuild. It never installs anything on a device. Every build is the
# DaybookPhone scheme: the app with its widget extension and Daybook for Apple Watch (DaybookWatch, in
# DaybookPhone.app/Watch, built for the watch or its simulator alongside; docs/watch.md).
#
#   scripts/build-ios.sh                    generate, then build for the iOS Simulator (no team needed)
#   scripts/build-ios.sh --test             ... build for testing instead, and run the unit tests on a simulator
#   scripts/build-ios.sh --build-for-testing
#                                           build for testing, without running the tests
#   scripts/build-ios.sh --test --skip-build
#                                           run the tests on what the last build for testing made, without
#                                           generating, resolving, or building anything
#                                           Simulator builds compile for this Mac's architecture only.
#   scripts/build-ios.sh --device           build for a physical iPhone with automatic signing;
#                                           needs DAYBOOK_TEAM_ID (or Apps/iOS/Config/Signing.local.xcconfig)
#                                           and profiles that already exist: the script never registers
#                                           identifiers (the watch app's local.daybook.watchkitapp too), the
#                                           app group, or the iCloud container (no -allowProvisioningUpdates).
#                                           Do that once, deliberately, in Xcode's Signing & Capabilities.
#   scripts/build-ios.sh --device --no-sign compile for a device without signing (a CI check); the watch app
#                                           compiles for the watch's architectures (arm64_32, arm64)
#   scripts/build-ios.sh --generate-only    just regenerate Apps/iOS/Daybook.xcodeproj
#   scripts/build-ios.sh --resolve          regenerate it and fetch the packages at Package.resolved's versions
#   scripts/build-ios.sh --archive          xcodebuild archive (Release) to Apps/iOS/build/DaybookPhone.xcarchive,
#                                           with the widget extension and the watch app; signed like --device.
#                                           Add --no-sign for an unsigned archive (a local or CI check).
#   scripts/build-ios.sh --archive --export upload
#                                           ... then -exportArchive with the app-store-connect method:
#                                           `upload` sends it to App Store Connect (TestFlight), `export`
#                                           writes the .ipa to Apps/iOS/build/Export. --export alone
#                                           exports an existing --archive-path.
#
# Options:
#   --simulator <name or UDID>   simulator for --test (default: scripts/ci/pick-simulator.sh's choice, an iPhone
#                                Duo, then an iPhone 18 Pro, then any iPhone, on the newest runtime with one)
#   --configuration <Debug|Release>   default Debug (Release for --archive)
#   --marketing-version <X.Y.Z>  MARKETING_VERSION (CFBundleShortVersionString of app, extension, and watch app)
#   --build-number <N>           CURRENT_PROJECT_VERSION (CFBundleVersion of app, extension, and watch app)
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
#                                certificates and profiles. Nothing else in this script uses them, and the
#                                script refuses them outside release.yml on GitHub Actions (AGENTS.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/build-common.sh
source "$ROOT/scripts/lib/build-common.sh"
APP="$ROOT/Apps/iOS"
PROJECT="$APP/Daybook.xcodeproj"
DERIVED="${DAYBOOK_IOS_DERIVED_DATA:-$APP/build/DerivedData}"
CONFIGURATION=""
MODE=simulator
RUN_TESTS=0
BUILD_FOR_TESTING=0
SKIP_BUILD=0
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
        --build-for-testing) BUILD_FOR_TESTING=1 ;;
        --skip-build) SKIP_BUILD=1 ;;
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
if (( BUILD_FOR_TESTING + SKIP_BUILD )) && [[ "$MODE" != simulator ]]; then
    echo "--build-for-testing and --skip-build are for the simulator" >&2
    exit 2
fi
if (( BUILD_FOR_TESTING && (RUN_TESTS || SKIP_BUILD) )); then
    echo "--build-for-testing builds without testing: --test already builds for testing" >&2
    exit 2
fi
if (( SKIP_BUILD && !RUN_TESTS )); then
    echo "--skip-build goes with --test" >&2
    exit 2
fi
if [[ -z "$CONFIGURATION" ]]; then
    if [[ "$MODE" == archive || "$MODE" == export ]]; then CONFIGURATION=Release; else CONFIGURATION=Debug; fi
fi

# The App Store Connect API key, in the release pipeline only (scripts/lib/build-common.sh). It brings
# -allowProvisioningUpdates; nothing else in this script passes it.
asc_key_arguments
AUTH=()
if (( ${#asc_key[@]} )); then AUTH=(-allowProvisioningUpdates "${asc_key[@]}"); fi

# The simulator for --test, chosen before anything is built, so a Mac without one hears it at once.
if [[ "$RUN_TESTS" == 1 && "$MODE" == simulator && -z "$SIMULATOR" ]]; then
    SIMULATOR="$("$ROOT/scripts/ci/pick-simulator.sh")" || {
        echo "No iPhone simulator is available for --test. Add one in Xcode's Devices and Simulators window, or pass --simulator." >&2
        exit 1
    }
fi

if [[ "$MODE" != export && "$SKIP_BUILD" == 0 ]]; then
    XCODEGEN="$(find_xcodegen)"
    generate_project "$XCODEGEN" "$APP" "$PROJECT" "$ROOT"
fi
[[ "$MODE" == generate ]] && exit 0

if [[ "$MODE" != export && "$SKIP_BUILD" == 0 ]]; then
    resolve_packages "$PROJECT" DaybookPhone "$ROOT" -derivedDataPath "$DERIVED"
fi
if [[ "$SKIP_BUILD" == 1 && ! -d "$PROJECT" ]]; then
    echo "--skip-build needs an earlier --build-for-testing (no $PROJECT)" >&2
    exit 1
fi
[[ "$MODE" == resolve ]] && exit 0

COMMON=(-project "$PROJECT" -scheme DaybookPhone -configuration "$CONFIGURATION" -derivedDataPath "$DERIVED" "${pinned[@]}")
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
    echo "Built $DERIVED/Build/Products/$CONFIGURATION-iphoneos/DaybookPhone.app, with Watch/DaybookWatch.app (not installed)."
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
    TEAM="$(team_id "$APP/Config/Signing.local.xcconfig")"
    [[ -n "$TEAM" ]] || { echo "--export needs DAYBOOK_TEAM_ID" >&2; exit 1; }
    OPTIONS="$APP/build/ExportOptions.plist"
    app_store_export_options "$OPTIONS" "$TEAM" "$EXPORT"
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

# Every simulator build is the same one, for this Mac's architecture, so each reuses what the last made. The
# generic destination alone would add x86_64, and alternating it with a simulator's own destination recompiles
# every target that imports a C module (MLX, Tokenizers) each time. The watch app builds for the watchOS
# Simulator with the same architecture.
SIMULATOR_BUILD=(-destination 'generic/platform=iOS Simulator' "ARCHS=$(uname -m)")
if [[ "$RUN_TESTS" == 0 && "$BUILD_FOR_TESTING" == 0 ]]; then
    xcodebuild "${COMMON[@]}" "${SIMULATOR_BUILD[@]}" build
    echo "Built $DERIVED/Build/Products/$CONFIGURATION-iphonesimulator/DaybookPhone.app, with Watch/DaybookWatch.app"
    exit 0
fi
if [[ "$SKIP_BUILD" == 0 ]]; then
    xcodebuild "${COMMON[@]}" "${SIMULATOR_BUILD[@]}" build-for-testing
fi
if [[ "$RUN_TESTS" == 1 ]]; then
    if [[ "$SIMULATOR" =~ ^[0-9A-F-]{36}$ ]]; then DESTINATION="id=$SIMULATOR"; else DESTINATION="platform=iOS Simulator,name=$SIMULATOR"; fi
    xcodebuild "${COMMON[@]}" -destination "$DESTINATION" test-without-building ${TEST_ARGS[@]+"${TEST_ARGS[@]}"}
fi
