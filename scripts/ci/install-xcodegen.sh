#!/bin/bash
# Installs a pinned XcodeGen release, verified by SHA-256, for CI.
#
#   scripts/ci/install-xcodegen.sh [--version 2.45.4] [--sha256 <digest of xcodegen.zip>] [--prefix DIR]
#
# Defaults match the version the projects are developed with (`xcodegen --version`). To move to a
# newer release, update both: the digest is the release asset's, shown by
#   gh api repos/yonaskolb/XcodeGen/releases/tags/<version> --jq '.assets[] | select(.name=="xcodegen.zip") | .digest'
# Puts xcodegen on $GITHUB_PATH and sets XCODEGEN in $GITHUB_ENV (build-app.sh and build-ios.sh read it).
set -euo pipefail

version="2.45.4"
sha256="090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef"
prefix="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/xcodegen"

fail() { echo "install-xcodegen.sh: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) version="${2-}"; shift ;;
        --sha256) sha256="${2-}"; shift ;;
        --prefix) prefix="${2-}"; shift ;;
        *) fail "unknown option: $1" ;;
    esac
    shift
done

zip="$(mktemp -d)/xcodegen.zip"
curl -fsSL --retry 3 -o "$zip" "https://github.com/yonaskolb/XcodeGen/releases/download/$version/xcodegen.zip"
actual="$(shasum -a 256 "$zip" | awk '{print $1}')"
[[ "$actual" == "$sha256" ]] || fail "xcodegen.zip $version has SHA-256 $actual, expected $sha256"

/bin/rm -rf "${prefix:?}"
mkdir -p "$prefix"
# The archive holds xcodegen/bin/xcodegen and xcodegen/share/xcodegen (its setting presets).
unzip -q "$zip" -d "$prefix"
/bin/rm -f "${zip:?}"
bin="$prefix/xcodegen/bin"
[[ -x "$bin/xcodegen" ]] || fail "unexpected archive layout"
"$bin/xcodegen" --version

if [[ -n "${GITHUB_PATH:-}" ]]; then echo "$bin" >> "$GITHUB_PATH"; fi
if [[ -n "${GITHUB_ENV:-}" ]]; then echo "XCODEGEN=$bin/xcodegen" >> "$GITHUB_ENV"; fi
