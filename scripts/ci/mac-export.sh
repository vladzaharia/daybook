#!/bin/bash
# Exports the Mac release archive (scripts/build-app.sh --archive-only) with Developer ID, for
# release.yml's mac job, which runs it inside `scripts/ci/secrets.sh run`.
#
#   scripts/ci/secrets.sh run -- scripts/ci/mac-export.sh
#
# With a Developer ID keychain (the .p12 fallback; secrets.sh sets DAYBOOK_SIGNING_KEYCHAIN), it installs
# the manually managed Developer ID profile (scripts/ci/asc-profile.sh) for the archived app's bundle ID
# (local.daybook) and the export signs manually with that identity. Without one, the export uses Xcode's cloud-managed signing with the API key (docs/release.md,
# Signing). Then build-app.sh --export-only packages dist/Daybook.app.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
if [[ -n "${DAYBOOK_SIGNING_KEYCHAIN:-}" ]]; then
    info="$here/../../build/macOS/Daybook.xcarchive/Products/Applications/Daybook.app/Contents/Info.plist"
    bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$info")"
    DAYBOOK_DEVELOPER_ID_PROFILE="$("$here/asc-profile.sh" --bundle-id "$bundle_id" --type MAC_APP_DIRECT \
        --keychain "$DAYBOOK_SIGNING_KEYCHAIN")"
    export DAYBOOK_DEVELOPER_ID_PROFILE
else
    echo "No Developer ID keychain: the export uses cloud-managed signing."
fi
exec "$here/../build-app.sh" --export-only "$@"
