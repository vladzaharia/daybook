#!/bin/bash
# Stand-ins for Xcode's command-line tools, for scripts/ci/tests/run-tests.sh: install a copy under each
# tool's name (xcodebuild, xcodegen, xcrun, codesign, ditto, hdiutil, spctl, security) on PATH. Each call
# is appended to $STUB_LOG as "<tool> <arguments>", and each tool leaves behind what the scripts look for
# next. Nothing is built, signed, or sent anywhere.
#
#   STUB_RESOLVE_CHANGES=1     -resolvePackageDependencies rewrites the project's Package.resolved
#   STUB_NOTARY=accepted|invalid|slow|accept-later
#                              how `xcrun notarytool` answers: slow means `wait` times out with the
#                              submission still in progress; accept-later means `info` says Accepted.
#                              A DMG's submission (ID 2222…) follows STUB_NOTARY_DMG when that's set.
#   STUB_PLIST_VERSION, STUB_PLIST_BUILD
#                              CFBundleShortVersionString and CFBundleVersion of the apps it makes
#   STUB_IDENTITY=1            security find-identity lists a Developer ID Application identity
#   STUB_XCODE_VERSION, STUB_XCODE_BUILD
#                              what `xcodebuild -version` reports (default Xcode 27.1, 27A9275)
#   STUB_IMPORT_FAILS=1        `security import` fails the way security -i reports it
#   STUB_ENTITLEMENTS=FILE     `codesign -d --entitlements` prints FILE (default: just the iCloud container)
# `security -i` reads commands from standard input: each line goes to $STUB_LOG as "security-stdin
# <line>", and its arguments, split as security splits them, to $STUB_LOG.args as a JSON array.
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
        if has -version "$@"; then
            printf 'Xcode %s\nBuild version %s\n' "${STUB_XCODE_VERSION:-27.1}" "${STUB_XCODE_BUILD:-27A9275}"
            exit 0
        elif has -showsdks "$@"; then
            printf '\tiOS 27.1 -sdk iphoneos27.1\n\tiOS Simulator 27.1 -sdk iphonesimulator27.1\n'
            exit 0
        elif has -showComponent "$@"; then
            printf 'Build Version: 27A266a\nStatus: installed\n'
            exit 0
        fi
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
                [[ "${3-}" == 2222* ]] && mode="${STUB_NOTARY_DMG:-$mode}"
                case "$sub" in
                    submit)
                        if [[ "${3-}" == *.dmg ]]; then
                            echo '{"id":"22222222-2222-3333-4444-555555555555","message":"Successfully uploaded file"}'
                        else
                            echo '{"id":"11111111-2222-3333-4444-555555555555","message":"Successfully uploaded file"}'
                        fi ;;
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
                if [[ -n "${STUB_ENTITLEMENTS:-}" ]]; then cat "$STUB_ENTITLEMENTS"
                else echo '<plist><dict><key>com.apple.developer.icloud-container-identifiers</key><array><string>iCloud.local.daybook</string></array></dict></plist>'
                fi
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
    curl) exit 22 ;;
    hdiutil)
        out="${*: -1}"
        printf 'dmg\n' > "$out"
        ;;
    security)
        if [[ "${1-}" == -i ]]; then
            while IFS= read -r line; do
                printf 'security-stdin %s\n' "$line" >> "$STUB_LOG"
                words="$(python3 -I -c 'import json, shlex, sys; print(json.dumps(shlex.split(sys.argv[1])))' "$line")"
                printf '%s\n' "$words" >> "$STUB_LOG.args"
                case "$(printf '%s' "$words" | jq -r '.[0]')" in
                    create-keychain) : > "$(printf '%s' "$words" | jq -r '.[-1]')" ;;
                    import)
                        if [[ "${STUB_IMPORT_FAILS:-0}" == 1 ]]; then
                            echo "security: SecKeychainItemImport: MAC verification failed during PKCS12 import (wrong password?)"
                            echo "import: returned -25264"
                        else
                            echo "1 identity imported."
                        fi ;;
                esac
            done
            exit 0
        fi
        case "${1-}" in
            list-keychains)
                has -s "$@" || echo '    "/Users/runner/Library/Keychains/login.keychain-db"'
                ;;
            delete-keychain) rm -f "${*: -1}" ;;
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
