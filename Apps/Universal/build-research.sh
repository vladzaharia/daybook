#!/bin/bash
# RESEARCH PROTOTYPE (docs/research/one-bundle.md). Generates Apps/Universal/DaybookUniversal.xcodeproj from
# Apps/Universal/project.yml and builds what the report describes: ad hoc, unsigned, or for the Simulator. It never
# uses a team, never passes -allowProvisioningUpdates, never uploads, and never launches what it builds.
#
#   Apps/Universal/build-research.sh generate     generate the project and fetch the packages at Package.resolved's versions
#   Apps/Universal/build-research.sh settings     print the build settings that differ between the platforms
#   Apps/Universal/build-research.sh mac          option (a): the Mac target, Debug, ad hoc (as build-app.sh --ad-hoc --debug)
#   Apps/Universal/build-research.sh mac-store    option (a): the Mac target as the `store` kind (local.daybook.phone,
#                                                 sandboxed, the store manifest), Debug, unsigned
#   Apps/Universal/build-research.sh phone        option (a): the iPhone app and widgets, Debug, for the Simulator
#   Apps/Universal/build-research.sh one-mac      option (b): DaybookOne for the Mac, Debug, ad hoc
#   Apps/Universal/build-research.sh one-phone    option (b): DaybookOne for the Simulator, Debug
#
# Environment: DAYBOOK_RESEARCH_DIR, where derived data and packages go (default build/Universal); XCODEGEN.
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
spec_dir="$root/Apps/Universal"
project="$spec_dir/DaybookUniversal.xcodeproj"
work="${DAYBOOK_RESEARCH_DIR:-$root/build/Universal}"
derived="$work/DerivedData"
packages="$work/SourcePackages"
pinned=(-onlyUsePackageVersionsFromResolvedFile)

generate() {
    local xcodegen="${XCODEGEN:-$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)}"
    "$xcodegen" generate --spec "$spec_dir/project.yml" --project "$spec_dir" --quiet
    local resolved="$project/project.xcworkspace/xcshareddata/swiftpm"
    mkdir -p "$resolved"
    /bin/cp -f "$root/Package.resolved" "$resolved/Package.resolved"
    xcodebuild -resolvePackageDependencies -project "$project" -scheme Daybook \
        -clonedSourcePackagesDirPath "$packages" "${pinned[@]}"
    if ! cmp -s "$root/Package.resolved" "$resolved/Package.resolved"; then
        echo "Xcode resolved other package versions than Package.resolved pins." >&2
        exit 1
    fi
}

build() {
    local scheme="$1" destination="$2"
    shift 2
    xcodebuild -project "$project" -scheme "$scheme" -configuration Debug -destination "$destination" \
        -derivedDataPath "$derived" -clonedSourcePackagesDirPath "$packages" "${pinned[@]}" \
        build "DAYBOOK_SOURCE_PACKAGES=$packages" "$@"
}

case "${1:-}" in
    generate) generate ;;
    settings)
        for target in Daybook DaybookPhone DaybookOne; do
            for sdk in macosx iphonesimulator; do
                if [[ "$target" == Daybook && "$sdk" != macosx ]] || [[ "$target" == DaybookPhone && "$sdk" != iphonesimulator ]]; then
                    continue
                fi
                echo "== $target ($sdk)"
                xcodebuild -project "$project" -target "$target" -sdk "$sdk" -configuration Release -showBuildSettings \
                    DAYBOOK_SIGNING=store 2>/dev/null |
                    grep -E '^ +(PRODUCT_BUNDLE_IDENTIFIER|PRODUCT_NAME|INFOPLIST_FILE|CODE_SIGN_ENTITLEMENTS|CODE_SIGN_STYLE|CODE_SIGN_IDENTITY|DAYBOOK_MIGRATION_MANIFEST|ENABLE_USER_SCRIPT_SANDBOXING|ENABLE_HARDENED_RUNTIME|MARKETING_VERSION|TARGETED_DEVICE_FAMILY|SUPPORTED_PLATFORMS|SUPPORTS_MACCATALYST|ARCHS) = ' || true
            done
        done
        ;;
    mac) build Daybook 'platform=macOS,arch=arm64' ARCHS=arm64 DAYBOOK_SIGNING=local ;;
    mac-store) build Daybook 'platform=macOS,arch=arm64' ARCHS=arm64 DAYBOOK_SIGNING=store CODE_SIGNING_ALLOWED=NO ;;
    phone) build DaybookPhone 'generic/platform=iOS Simulator' ;;
    one-mac) build DaybookOne 'platform=macOS,arch=arm64' ARCHS=arm64 DAYBOOK_SIGNING=local ;;
    one-phone) build DaybookOne 'generic/platform=iOS Simulator' ;;
    *) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed -E 's/^# ?//'; exit 2 ;;
esac
