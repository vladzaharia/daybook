#!/bin/bash
# Stand-ins for Xcode's command-line tools, for scripts/ci/tests/run-tests.sh: install a copy under each
# tool's name (xcodebuild, xcodegen, xcrun, codesign, ditto, hdiutil, spctl, security) on PATH. Each call
# is appended to $STUB_LOG as "<tool> <arguments>", and each tool leaves behind what the scripts look for
# next. Nothing is built, signed, or sent anywhere.
#
#   STUB_RESOLVE_CHANGES=1     -resolvePackageDependencies rewrites the project's Package.resolved
#   STUB_NOTARY=accepted|invalid|slow|accept-later
#                              how `xcrun notarytool` answers: slow means `wait` times out with the
#                              submission still in progress; accept-later means `info` says Accepted
#   STUB_PLIST_VERSION, STUB_PLIST_BUILD
#                              CFBundleShortVersionString and CFBundleVersion of the apps it makes
#   STUB_IDENTITY=1            security find-identity lists a Developer ID Application identity
set -euo pipefail
tool="$(basename "$0")"
printf '%s' "$tool" >> "${STUB_LOG:?}"
printf ' %s' "$@" >> "$STUB_LOG"
printf '\n' >> "$STUB_LOG"

# value_of FLAG ARGS...: the argument after FLAG.
value_of() {
    local flag="$1"; shift
    while [[ $# -gt 1 ]]; do
        [[ "$1" == "$flag" ]] && { printf '%s' "$2"; return 0; }
        shift
    done
    return 0
}
has() { local word="$1"; shift; local a; for a in "$@"; do [[ "$a" == "$word" ]] && return 0; done; return 1; }

make_app() {
    # make_app DIR NAME: an app bundle with an Info.plist.
    local app="$1/$2.app"
    mkdir -p "$app/Contents/MacOS"
    printf '#!/bin/sh\n' > "$app/Contents/MacOS/$2"
    plutil -create xml1 "$app/Contents/Info.plist" 2>/dev/null || printf '<plist/>\n' > "$app/Contents/Info.plist"
    plutil -insert CFBundleIdentifier -string local.daybook.app "$app/Contents/Info.plist" 2>/dev/null || true
    plutil -insert CFBundleShortVersionString -string "${STUB_PLIST_VERSION:-1.4.0}" "$app/Contents/Info.plist" 2>/dev/null || true
    plutil -insert CFBundleVersion -string "${STUB_PLIST_BUILD:-1057}" "$app/Contents/Info.plist" 2>/dev/null || true
}

case "$tool" in
    xcodebuild)
        scheme="$(value_of -scheme "$@")"
        app_name=Daybook
        [[ "$scheme" == DaybookPhone ]] && app_name=DaybookPhone
        if has -resolvePackageDependencies "$@"; then
            project="$(value_of -project "$@")"
            if [[ "${STUB_RESOLVE_CHANGES:-0}" == 1 && -n "$project" ]]; then
                printf '{"changed": true}\n' > "$project/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
            fi
        elif has -exportArchive "$@"; then
            make_app "$(value_of -exportPath "$@")" "$app_name"
        elif has archive "$@"; then
            make_app "$(value_of -archivePath "$@")/Products/Applications" "$app_name"
        elif has build "$@"; then
            make_app "$(value_of -derivedDataPath "$@")/Build/Products/$(value_of -configuration "$@")" "$app_name"
        fi
        ;;
    xcodegen)
        dir="$(value_of --project "$@")"
        mkdir -p "$dir/DaybookMac.xcodeproj" "$dir/Daybook.xcodeproj"
        ;;
    xcrun)
        case "${1-}" in
            metal) echo "Apple metal version 32023.921" ;;
            notarytool)
                sub="${2-}"
                mode="${STUB_NOTARY:-accepted}"
                case "$sub" in
                    submit) echo '{"id":"11111111-2222-3333-4444-555555555555","message":"Successfully uploaded file"}' ;;
                    wait)
                        case "$mode" in
                            accepted) echo "{\"id\":\"$3\",\"status\":\"Accepted\"}" ;;
                            invalid) echo "{\"id\":\"$3\",\"status\":\"Invalid\"}" ;;
                            slow|accept-later) echo "Timeout of $(value_of --timeout "$@") reached" >&2; exit 1 ;;
                        esac ;;
                    info)
                        case "$mode" in
                            accepted|accept-later) echo "{\"id\":\"$3\",\"status\":\"Accepted\"}" ;;
                            invalid) echo "{\"id\":\"$3\",\"status\":\"Invalid\"}" ;;
                            slow) echo "{\"id\":\"$3\",\"status\":\"In Progress\"}" ;;
                        esac ;;
                    log) echo '{"issues": []}' ;;
                esac
                ;;
        esac
        ;;
    codesign)
        if has -dv "$@" || has -d "$@"; then
            if has --entitlements "$@"; then
                echo '<plist><dict><key>com.apple.developer.icloud-container-identifiers</key><array><string>iCloud.local.daybook</string></array></dict></plist>'
            else
                printf 'Identifier=local.daybook.app\nAuthority=Developer ID Application: Example (48H7CLBV8Y)\nTeamIdentifier=48H7CLBV8Y\n' >&2
            fi
        fi
        ;;
    ditto)
        if has -c "$@"; then
            out="${*: -1}"
            printf 'zip of %s\n' "${*: -2:1}" > "$out"
        elif has -x "$@"; then
            dest="${*: -1}"
            mkdir -p "$dest"
            make_app "$dest" Daybook
        else
            src="${*: -2:1}"
            dest="${*: -1}"
            mkdir -p "$(dirname "$dest")"
            cp -R "$src" "$dest"
        fi
        ;;
    hdiutil)
        out="${*: -1}"
        printf 'dmg\n' > "$out"
        ;;
    security)
        case "${1-}" in
            find-identity)
                if [[ "${STUB_IDENTITY:-0}" == 1 ]]; then
                    echo '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Example (48H7CLBV8Y)"'
                fi
                echo "     1 valid identities found"
                ;;
        esac
        ;;
esac
exit 0
