#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
cd "$repo_dir"
configuration=release
if [[ "${1:-}" == "--debug" ]]; then configuration=debug; fi

if ! xcrun metal --version >/dev/null 2>&1; then
    print -u2 "The Xcode Metal compiler is required. Run: xcodebuild -downloadComponent MetalToolchain"
    exit 1
fi

swift build -c "$configuration" --product Daybook
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="$repo_dir/dist/Daybook.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$repo_dir/build/Daybook.iconset"
# Resolved package licenses can be read-only; make this generated bundle replaceable.
chmod -R u+w "$app_dir"
cp "$binary_dir/Daybook" "$app_dir/Contents/MacOS/Daybook"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"

# SwiftPM resource bundles include the MLX Metal library and local package data.
for resource_bundle in "$binary_dir"/*.bundle(N); do
    rsync -a --delete "$resource_bundle/" "$app_dir/Contents/Resources/${resource_bundle:t}/"
done
swift scripts/make-icon.swift "$repo_dir/build/Daybook.iconset"
iconutil -c icns "$repo_dir/build/Daybook.iconset" -o "$app_dir/Contents/Resources/Daybook.icns"
cp THIRD_PARTY_NOTICES.md "$app_dir/Contents/Resources/ThirdPartyNotices.md"
mkdir -p "$app_dir/Contents/Resources/Licenses"
for package_dir in .build/checkouts/*(N/); do
    for license_path in "$package_dir"/{LICENSE,LICENSE.md,LICENSE.txt,LICENSE-MIT,COPYING}(N); do
        cp "$license_path" "$app_dir/Contents/Resources/Licenses/${package_dir:t}-${license_path:t}.txt"
    done
done
sign_identity="${DAYBOOK_SIGN_IDENTITY:--}"
# Back-deployed Swift features can need compatibility dylibs even when the Mac
# already has the Swift standard library. Embed them instead of relying on Xcode.
python3 scripts/bundle-runtime.py "$app_dir/Contents/MacOS/Daybook" "$app_dir/Contents/Frameworks" "$sign_identity"
sign_options=(--force --deep --sign "$sign_identity" --options runtime --entitlements Resources/Daybook.entitlements)
if [[ "$sign_identity" != "-" ]]; then sign_options+=(--timestamp); fi
codesign "${sign_options[@]}" "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"
ditto -c -k --keepParent "$app_dir" "$repo_dir/dist/Daybook-macOS-arm64.zip"
if [[ -n "${DAYBOOK_NOTARY_PROFILE:-}" ]]; then
    if [[ "$sign_identity" == "-" ]]; then
        print -u2 "Notarization needs DAYBOOK_SIGN_IDENTITY set to a Developer ID Application identity."
        exit 1
    fi
    xcrun notarytool submit "$repo_dir/dist/Daybook-macOS-arm64.zip" --keychain-profile "$DAYBOOK_NOTARY_PROFILE" --wait
    xcrun stapler staple "$app_dir"
    ditto -c -k --keepParent "$app_dir" "$repo_dir/dist/Daybook-macOS-arm64.zip"
fi
print "App: $app_dir"
print "Archive: $repo_dir/dist/Daybook-macOS-arm64.zip"
