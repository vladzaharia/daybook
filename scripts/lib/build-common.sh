# shellcheck shell=bash
# shellcheck disable=SC2034 # the scripts that source this read its variables
#
# What scripts/build-app.sh and scripts/build-ios.sh share, so neither can drift from the other: the guard on the App
# Store Connect API key, generating the Xcode project with XcodeGen and holding its packages to Package.resolved, the
# team from Config/Signing.local.xcconfig, and the app-store-connect export options. Sourced by both, never run.

# asc_key_arguments: the App Store Connect API key (DAYBOOK_ASC_KEY_PATH, DAYBOOK_ASC_KEY_ID, DAYBOOK_ASC_ISSUER_ID) as
# xcodebuild's -authenticationKey… arguments, in the array asc_key; empty without a key. All three variables or none.
# The key brings -allowProvisioningUpdates, which only the release pipeline may pass (AGENTS.md), so it's refused
# anywhere but release.yml on GitHub Actions. Either refusal exits 2, before anything runs.
asc_key=()
asc_key_arguments() {
    local name count=0
    for name in DAYBOOK_ASC_KEY_PATH DAYBOOK_ASC_KEY_ID DAYBOOK_ASC_ISSUER_ID; do
        if [[ -n "${!name:-}" ]]; then count=$(( count + 1 )); fi
    done
    asc_key=()
    if (( count == 0 )); then return 0; fi
    if (( count < 3 )); then
        echo "Set all of DAYBOOK_ASC_KEY_PATH, DAYBOOK_ASC_KEY_ID, and DAYBOOK_ASC_ISSUER_ID, or none." >&2
        exit 2
    fi
    if [[ "${GITHUB_ACTIONS:-}" != true || "${GITHUB_WORKFLOW_REF:-}" != */.github/workflows/release.yml@* ]]; then
        echo "The App Store Connect API key is for the release pipeline only (.github/workflows/release.yml), because it" >&2
        echo "passes -allowProvisioningUpdates. Build with your Xcode account and existing profiles instead (AGENTS.md)." >&2
        exit 2
    fi
    asc_key=(-authenticationKeyPath "$DAYBOOK_ASC_KEY_PATH" -authenticationKeyID "$DAYBOOK_ASC_KEY_ID"
             -authenticationKeyIssuerID "$DAYBOOK_ASC_ISSUER_ID")
}

# find_xcodegen: prints the path to xcodegen ($XCODEGEN, then PATH, then Homebrew's), or says how to install it and
# fails. Use it in an assignment, so the failure stops the script.
find_xcodegen() {
    local path="${XCODEGEN:-$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)}"
    if [[ ! -x "$path" ]]; then
        echo "XcodeGen is required: brew install xcodegen" >&2
        return 1
    fi
    printf '%s\n' "$path"
}

# generate_project XCODEGEN SPEC_DIR PROJECT ROOT: generates PROJECT from SPEC_DIR/project.yml, then copies
# ROOT/Package.resolved into it, so Xcode resolves the versions `swift build` does.
generate_project() {
    local xcodegen="$1" spec_dir="$2" project="$3" root="$4"
    local resolved_dir="$project/project.xcworkspace/xcshareddata/swiftpm"
    echo "Generating $project"
    "$xcodegen" generate --spec "$spec_dir/project.yml" --project "$spec_dir" --quiet
    mkdir -p "$resolved_dir"
    /bin/cp -f "$root/Package.resolved" "$resolved_dir/Package.resolved"
}

# pinned: holds every resolution, build, test, and archive to the versions in Package.resolved.
pinned=(-onlyUsePackageVersionsFromResolvedFile)

# resolve_packages PROJECT SCHEME ROOT [XCODEBUILD ARGUMENTS...]: fetches PROJECT's packages at Package.resolved's
# versions, and fails if Xcode would change that file.
resolve_packages() {
    local project="$1" scheme="$2" root="$3"
    shift 3
    local resolved="$project/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    xcodebuild -resolvePackageDependencies -project "$project" -scheme "$scheme" "$@" "${pinned[@]}"
    if ! cmp -s "$root/Package.resolved" "$resolved"; then
        echo "Xcode resolved other package versions than Package.resolved pins:" >&2
        diff -u "$root/Package.resolved" "$resolved" >&2 || true
        exit 1
    fi
}

# team_id LOCAL_CONFIG: prints DAYBOOK_TEAM_ID, or else the last DAYBOOK_TEAM_ID in LOCAL_CONFIG
# (Config/Signing.local.xcconfig) when that file exists; nothing when neither has one.
team_id() {
    if [[ -n "${DAYBOOK_TEAM_ID:-}" ]]; then
        printf '%s\n' "$DAYBOOK_TEAM_ID"
    elif [[ -f "$1" ]]; then
        sed -nE 's/^[[:space:]]*DAYBOOK_TEAM_ID[[:space:]]*=[[:space:]]*([A-Z0-9]+).*/\1/p' "$1" | tail -1
    fi
}

# app_store_export_options PLIST TEAM DESTINATION: writes PLIST, the export options for the app-store-connect method
# with automatic signing. DESTINATION is upload (straight to App Store Connect) or export (a file). The pipeline sets
# the version and build number, so App Store Connect mustn't change them.
app_store_export_options() {
    local plist="$1" team="$2" destination="$3"
    mkdir -p "$(dirname "$plist")"
    /bin/rm -f "${plist:?}"
    plutil -create xml1 "$plist"
    plutil -insert method -string app-store-connect "$plist"
    plutil -insert destination -string "$destination" "$plist"
    plutil -insert signingStyle -string automatic "$plist"
    plutil -insert teamID -string "$team" "$plist"
    plutil -insert uploadSymbols -bool YES "$plist"
    plutil -insert manageAppVersionAndBuildNumber -bool NO "$plist"
}
