#!/bin/bash
# Selects the Xcode a CI job builds with and checks it's the one expected.
#
#   scripts/ci/select-xcode.sh [--xcode /Applications/Xcode_27.1.app] [--expect 27.1]
#                              [--sdk iphoneos27.1]... [--metal]
#
#   --xcode    the Xcode app (default $DAYBOOK_XCODE, then /Applications/Xcode_27.1.app). On the
#              `xcode-27` runner image Xcode_27.1.app is the 27.1 install (27A9275); Xcode.app is 27.0.
#   --expect   fail unless `xcodebuild -version` starts with "Xcode <this>" (default 27.1)
#   --sdk      fail unless this SDK is installed (repeatable). The iPhone app needs iphoneos27.1 and
#              iphonesimulator27.1 for the iPhone Duo hinge APIs.
#   --metal    make sure the Metal toolchain is installed (MLX compiles Metal shaders). The runner
#              image doesn't include it; this downloads it with xcodebuild -downloadComponent.
#
# Exports DEVELOPER_DIR through $GITHUB_ENV (no sudo xcode-select needed), so every later step,
# including `swift`, uses this Xcode, and DAYBOOK_XCODE_BUILD (e.g. 27A9275) for cache keys.
set -euo pipefail

xcode="${DAYBOOK_XCODE:-/Applications/Xcode_27.1.app}"
expect="27.1"
sdks=()
metal=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
fail() { echo "select-xcode.sh: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --xcode) xcode="${2-}"; shift ;;
        --expect) expect="${2-}"; shift ;;
        --sdk) sdks+=("${2-}"); shift ;;
        --metal) metal=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "unknown option: $1" ;;
    esac
    shift
done

developer_dir="$xcode/Contents/Developer"
if [[ ! -d "$developer_dir" ]]; then
    echo "Installed Xcodes:" >&2
    ls -d /Applications/Xcode*.app >&2 || true
    fail "$xcode isn't installed on this runner. The runner image may have changed: see docs/release.md, Troubleshooting."
fi
export DEVELOPER_DIR="$developer_dir"
[[ -n "${GITHUB_ENV:-}" ]] && echo "DEVELOPER_DIR=$developer_dir" >> "$GITHUB_ENV"

version="$(xcodebuild -version)"
echo "$version"
[[ "$(printf '%s\n' "$version" | head -1)" == "Xcode $expect"* ]] || fail "expected Xcode $expect at $xcode"
build="$(printf '%s\n' "$version" | sed -n 's/^Build version //p')"
[[ -n "${GITHUB_ENV:-}" ]] && echo "DAYBOOK_XCODE_BUILD=$build" >> "$GITHUB_ENV"
swift --version 2>&1 | head -1

if (( ${#sdks[@]} )); then
    installed="$(xcodebuild -showsdks)"
    for sdk in "${sdks[@]}"; do
        printf '%s\n' "$installed" | grep -q -- "-sdk $sdk\$" || fail "SDK $sdk isn't in $xcode"
        echo "SDK $sdk: present"
    done
fi

if (( metal )); then
    if ! xcrun metal --version >/dev/null 2>&1; then
        echo "Downloading the Metal toolchain for $(printf '%s\n' "$version" | head -1)"
        for attempt in 1 2 3; do
            xcodebuild -downloadComponent MetalToolchain && break
            (( attempt < 3 )) || fail "couldn't download the Metal toolchain"
            sleep $(( attempt * 15 ))
        done
        xcrun --kill-cache || true
    fi
    xcrun metal --version 2>&1 | head -1
fi
