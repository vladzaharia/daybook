#!/bin/bash
# Checks a built Daybook.app's bundle ID, App Sandbox entitlements, and container migration manifest against what its
# kind of build must carry (docs/sandbox.md). Reads the signature, so it checks what was signed, not the source files.
#
#   scripts/ci/check-mac-app.sh --app dist/Daybook.app --kind adhoc|rehearsal|signed|signed-sandbox
#
#   adhoc           sandboxed, local.daybook.adhoc, the /private/tmp/daybook/ exception and no other, no manifest
#   rehearsal       sandboxed, local.daybook.rehearsal…, the same exception, the rehearsal's manifest
#   signed          local.daybook, not sandboxed, no manifest (the Developer ID default until the switch)
#   signed-sandbox  local.daybook, sandboxed, no temporary exceptions, the manifest that moves ${ApplicationSupport}/Daybook,
#                   ${BundleId}'s preferences, and local.daybook.app's (releases before the one bundle ID). The App Store
#                   and TestFlight build (build-app.sh --app-store), and Developer ID with --sandbox, are this kind
#
# Every sandboxed kind needs the capabilities Daybook uses: audio input, microphone, Bluetooth, network client and
# server, user-selected files, and app-scoped bookmarks. Exits 1 with every problem listed.
set -euo pipefail

app=""
kind=""
while (( $# )); do
    case "$1" in
        --app) app="${2-}"; shift ;;
        --kind) kind="${2-}"; shift ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed -E 's/^# ?//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
case "$kind" in
    adhoc|rehearsal|signed|signed-sandbox) ;;
    *) echo "--kind is adhoc, rehearsal, signed, or signed-sandbox" >&2; exit 2 ;;
esac
[[ -d "$app" ]] || { echo "No app at '$app'" >&2; exit 2; }

work="$(mktemp -d)"
trap '/bin/rm -rf "$work"' EXIT
problems=0
problem() { echo "::error::$1" >&2; problems=$(( problems + 1 )); }

bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)"
entitlements="$work/entitlements.plist"
if ! codesign -d --entitlements - --xml "$app" > "$entitlements" 2>/dev/null || [[ ! -s "$entitlements" ]]; then
    plutil -create xml1 "$entitlements"
fi
manifest="$app/Contents/Resources/container-migration.plist"

# value KEY: a boolean or string entitlement's value; list KEY: an array's, as JSON. Empty when it's missing. plutil
# reads dots as a key path, so they're escaped.
value() { plutil -extract "${1//./\\.}" raw -o - "$entitlements" 2>/dev/null || true; }
list() { plutil -extract "${1//./\\.}" json -o - "$entitlements" 2>/dev/null | tr -d '\134' || true; }
exceptions="$(plutil -p "$entitlements" | grep -o '"com\.apple\.security\.temporary-exception\.[^"]*"' | tr -d '"' | sort -u || true)"
sandboxed="$(value com.apple.security.app-sandbox)"

expect_bundle() {
    if [[ "$1" == *"*" ]]; then
        [[ "$bundle_id" == "${1%\*}"* ]] || problem "bundle ID is '$bundle_id', expected $1"
    else
        [[ "$bundle_id" == "$1" ]] || problem "bundle ID is '$bundle_id', expected $1"
    fi
}

expect_sandboxed() {
    [[ "$sandboxed" == true ]] || problem "com.apple.security.app-sandbox isn't true"
    local key
    for key in com.apple.security.device.audio-input com.apple.security.device.microphone com.apple.security.device.bluetooth \
               com.apple.security.network.client com.apple.security.network.server \
               com.apple.security.files.user-selected.read-write com.apple.security.files.bookmarks.app-scope; do
        [[ "$(value "$key")" == true ]] || problem "$key isn't true"
    done
}

expect_scratch_exception_only() {
    [[ "$exceptions" == com.apple.security.temporary-exception.files.absolute-path.read-write ]] ||
        problem "temporary exceptions are [${exceptions//$'\n'/, }], expected only files.absolute-path.read-write"
    local paths
    paths="$(list com.apple.security.temporary-exception.files.absolute-path.read-write)"
    [[ "$paths" == '["/private/tmp/daybook/"]' ]] || problem "the read-write exception is $paths, expected [\"/private/tmp/daybook/\"]"
}

expect_manifest() {
    if [[ ! -f "$manifest" ]]; then problem "no container-migration.plist in Contents/Resources"; return; fi
    plutil -lint "$manifest" >/dev/null || { problem "container-migration.plist isn't a valid property list"; return; }
    local moves
    moves="$(plutil -extract Move json -o - "$manifest" 2>/dev/null | tr -d '\134' || true)"
    [[ "$moves" == "$1" ]] || problem "the manifest moves $moves, expected $1"
}

expect_no_manifest() {
    [[ ! -e "$manifest" ]] || problem "this build mustn't carry container-migration.plist: only signed sandboxed builds and the rehearsal move a library"
}

case "$kind" in
    adhoc)
        expect_bundle local.daybook.adhoc
        expect_sandboxed
        expect_scratch_exception_only
        expect_no_manifest
        ;;
    rehearsal)
        expect_bundle 'local.daybook.rehearsal*'
        expect_sandboxed
        expect_scratch_exception_only
        # shellcheck disable=SC2016 # the manifest's own variables, never expanded here
        expect_manifest '[["${ApplicationSupport}/Daybook Rehearsal","${ApplicationSupport}/Daybook"],"${Library}/Preferences/${BundleId}.plist"]'
        ;;
    signed)
        expect_bundle local.daybook
        [[ "$sandboxed" != true ]] || problem "the default signed build isn't sandboxed until the switch (DAYBOOK_SANDBOX)"
        [[ -z "$exceptions" ]] || problem "signed builds carry no temporary exceptions: [${exceptions//$'\n'/, }]"
        expect_no_manifest
        ;;
    signed-sandbox)
        expect_bundle local.daybook
        expect_sandboxed
        [[ -z "$exceptions" ]] || problem "signed builds carry no temporary exceptions: [${exceptions//$'\n'/, }]"
        # shellcheck disable=SC2016 # the manifest's own variables, never expanded here
        expect_manifest '["${ApplicationSupport}/Daybook","${Library}/Preferences/${BundleId}.plist","${Library}/Preferences/local.daybook.app.plist"]'
        ;;
esac

if (( problems )); then
    echo "$app: $problems problem(s) as a $kind build" >&2
    exit 1
fi
echo "$app: as expected for $kind ($bundle_id, sandboxed: ${sandboxed:-false}, manifest: $([[ -f "$manifest" ]] && echo yes || echo no))"
