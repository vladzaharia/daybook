#!/bin/bash
# Selects the Xcode a CI job builds with and checks it's the one expected.
#
#   scripts/ci/select-xcode.sh [--xcode /Applications/Xcode_27.1.app] [--expect 27.1]
#                              [--expect-build 27A9275] [--sdk iphoneos27.1]... [--metal]
#
#   --xcode    the Xcode app (default $DAYBOOK_XCODE, then /Applications/Xcode_27.1.app). On the
#              `xcode-27` runner image Xcode_27.1.app is the 27.1 install (27A9275); Xcode.app is 27.0.
#   --expect   fail unless `xcodebuild -version` is Xcode <this> or a patch release of it (27.1, 27.1.1;
#              not 27.10). Default 27.1.
#   --expect-build
#              also fail unless the build is exactly this (release.yml passes the repository variable
#              DAYBOOK_RELEASE_XCODE_BUILD, default 27A9275), so a release never ships from an Xcode
#              build that CI and the development Macs haven't used
#   --sdk      fail unless this SDK is installed (repeatable). The iPhone app needs iphoneos27.1 and
#              iphonesimulator27.1 for the iPhone Duo hinge APIs.
#   --metal    make sure the Metal toolchain is installed (MLX compiles Metal shaders). The runner
#              image doesn't include it; this downloads it with xcodebuild -downloadComponent. Apple
#              doesn't let the download be pinned, so its version goes to the run summary.
#
# Exports DEVELOPER_DIR through $GITHUB_ENV (no sudo xcode-select needed), so every later step,
# including `swift`, uses this Xcode, and DAYBOOK_XCODE_BUILD (e.g. 27A9275) for cache keys. Writes
# the Xcode version and build (and the Metal toolchain's) to $GITHUB_STEP_SUMMARY when it's set.
set -euo pipefail

xcode="${DAYBOOK_XCODE:-/Applications/Xcode_27.1.app}"
expect="27.1"
expect_build=""
sdks=()
metal=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
fail() { echo "select-xcode.sh: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --xcode) xcode="${2-}"; shift ;;
        --expect) expect="${2-}"; shift ;;
        --expect-build) expect_build="${2-}"; shift ;;
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

summary() { if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"; fi; }

version="$(xcodebuild -version)"
echo "$version"
first="$(printf '%s\n' "$version" | head -1)"
[[ "$first" == "Xcode $expect" || "$first" == "Xcode $expect."* ]] || fail "expected Xcode $expect at $xcode, found $first"
build="$(printf '%s\n' "$version" | sed -n 's/^Build version //p')"
if [[ -n "$expect_build" && "$build" != "$expect_build" ]]; then
    fail "$first at $xcode is build $build, not $expect_build. The runner image changed: check its Xcode, then set the DAYBOOK_RELEASE_XCODE_BUILD repository variable (docs/release.md, Runner and Xcode)."
fi
if [[ -n "${GITHUB_ENV:-}" ]]; then echo "DAYBOOK_XCODE_BUILD=$build" >> "$GITHUB_ENV"; fi
swift --version 2>&1 | head -1
summary "### Toolchain"
summary "- $first ($build) at \`$xcode\`${expect_build:+, the release build}"

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
    metal="$(xcrun metal --version 2>&1 | head -1)"
    component="$(xcodebuild -showComponent MetalToolchain 2>/dev/null | sed -n 's/^Build Version: //p' | head -1 || true)"
    echo "Metal toolchain ${component:-?}: $metal"
    summary "- Metal toolchain ${component:-(build unknown)}: $metal"
fi
