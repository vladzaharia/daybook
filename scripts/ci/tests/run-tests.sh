#!/bin/bash
# Tests for the release helpers in scripts/ci. Offline: nothing here talks to Apple or GitHub.
#
#   scripts/ci/tests/run-tests.sh
#
#   version.sh            tag, branch, re-run, and rejection vectors
#   asc-jwt.sh            fixed header and payload vectors; the signature verified by openssl and, on
#                         macOS, by CryptoKit (an independent implementation)
#   asc-testflight.sh     the full request sequence against a local mock of the App Store Connect API
#   release-notes.sh      annotated and lightweight tags in a throwaway repository
#   check-ios-archive.sh  synthetic archives: export compliance, icon, versions (macOS: needs plutil)
#   setup-github.sh       the dry run prints the plan and never calls gh
# Runs on macOS (bash 3.2) and Linux.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
ci="$(cd "$here/.." && pwd)"
work="$(mktemp -d)"
mock_pid=""
cleanup() {
    if [[ -n "$mock_pid" ]]; then kill "$mock_pid" 2>/dev/null || true; fi
    /bin/rm -rf "${work:?}"
}
trap cleanup EXIT

passed=0
failed=0
pass() { passed=$(( passed + 1 )); echo "  ok    $1"; }
flunk() { failed=$(( failed + 1 )); echo "  FAIL  $1" >&2; }
expect_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else flunk "$1: expected [$2], got [$3]"; fi; }
expect_ok() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else flunk "$name"; fi; }
expect_fail() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then flunk "$name (succeeded)"; else pass "$name"; fi; }
b64url_decode() { local s="$1"; while (( ${#s} % 4 )); do s="$s="; done; printf '%s' "$s" | tr '_-' '/+' | base64 -d; }
macos() { [[ "$(uname)" == Darwin ]]; }

# --- version.sh ----------------------------------------------------------------------------------------
echo "version.sh"
expect_eq "tag" "marketing_version=1.4.0
build_number=1057
tag=v1.4.0
is_tag=true
prerelease=false" "$("$ci/version.sh" --ref refs/tags/v1.4.0 --run-number 57)"
expect_eq "prerelease tag" "1.4.0 true" \
    "$("$ci/version.sh" --ref refs/tags/v1.4.0-rc.1 --run-number 1 | awk -F= '/^marketing_version|^prerelease/ {printf "%s%s", sep, $2; sep=" "}')"
expect_eq "re-run attempt" "build_number=1057.2" "$("$ci/version.sh" --ref refs/tags/v1.4.0 --run-number 57 --run-attempt 2 | grep build_number)"
expect_eq "custom offset" "build_number=5" "$("$ci/version.sh" --ref refs/tags/v0.1.0 --run-number 5 --offset 0 | grep build_number)"
expect_eq "branch with version" "marketing_version=2.0.10 is_tag=false" \
    "$("$ci/version.sh" --ref refs/heads/main --version 2.0.10 --run-number 9 | grep -E '^(marketing_version|is_tag)=' | paste -sd ' ' -)"
expect_eq "matching --version on a tag" "marketing_version=1.4.0" "$("$ci/version.sh" --ref refs/tags/v1.4.0 --version 1.4.0 --run-number 1 | head -1)"
expect_fail "branch without version" "$ci/version.sh" --ref refs/heads/main --run-number 1
expect_fail "two-part tag" "$ci/version.sh" --ref refs/tags/v1.4 --run-number 1
expect_fail "four-part tag" "$ci/version.sh" --ref refs/tags/v1.4.0.1 --run-number 1
expect_fail "leading zero" "$ci/version.sh" --ref refs/tags/v1.04.0 --run-number 1
expect_fail "tag without v" "$ci/version.sh" --ref refs/tags/1.4.0 --run-number 1
expect_fail "mismatched --version" "$ci/version.sh" --ref refs/tags/v1.4.0 --version 1.5.0 --run-number 1
expect_fail "zero run number" "$ci/version.sh" --ref refs/tags/v1.4.0 --run-number 0
expect_fail "pull request ref" "$ci/version.sh" --ref refs/pull/3/merge --version 1.0.0 --run-number 1

# --- asc-jwt.sh ----------------------------------------------------------------------------------------
echo "asc-jwt.sh"
key="$work/AuthKey_ABC123DEFG.p8"
openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null | openssl pkcs8 -topk8 -nocrypt -out "$key"
openssl ec -in "$key" -pubout -out "$work/public.pem" 2>/dev/null
issuer="57246542-96fe-1a63-e053-0824d011072a"
token="$("$ci/asc-jwt.sh" --key "$key" --key-id ABC123DEFG --issuer-id "$issuer" --issued-at 1767225600 --lifetime 600)"
IFS=. read -r header payload signature <<< "$token"
# Known vectors: base64url of the exact JSON App Store Connect expects.
expect_eq "header vector" "eyJhbGciOiJFUzI1NiIsImtpZCI6IkFCQzEyM0RFRkciLCJ0eXAiOiJKV1QifQ" "$header"
expect_eq "payload vector" "eyJpc3MiOiI1NzI0NjU0Mi05NmZlLTFhNjMtZTA1My0wODI0ZDAxMTA3MmEiLCJpYXQiOjE3NjcyMjU2MDAsImV4cCI6MTc2NzIyNjIwMCwiYXVkIjoiYXBwc3RvcmVjb25uZWN0LXYxIn0" "$payload"
expect_eq "decoded payload" '{"iss":"57246542-96fe-1a63-e053-0824d011072a","iat":1767225600,"exp":1767226200,"aud":"appstoreconnect-v1"}' "$(b64url_decode "$payload")"
expect_eq "signature is 64 raw bytes" "64" "$(b64url_decode "$signature" | wc -c | tr -d ' ')"
expect_eq "no padding or unsafe characters" "" "$(printf '%s' "$token" | tr -d 'A-Za-z0-9_.-')"

# Verify with openssl: rebuild the DER signature from r || s.
raw_hex="$(b64url_decode "$signature" | od -An -v -tx1 | tr -d ' \n')"
printf 'asn1=SEQUENCE:sig\n[sig]\nr=INTEGER:0x%s\ns=INTEGER:0x%s\n' "${raw_hex:0:64}" "${raw_hex:64:64}" > "$work/sig.conf"
openssl asn1parse -genconf "$work/sig.conf" -out "$work/sig.der" -noout >/dev/null
printf '%s.%s' "$header" "$payload" > "$work/input"
expect_ok "openssl verifies the signature" openssl dgst -sha256 -verify "$work/public.pem" -signature "$work/sig.der" "$work/input"
printf '%s.%sX' "$header" "$payload" > "$work/tampered"
expect_fail "openssl rejects a tampered token" openssl dgst -sha256 -verify "$work/public.pem" -signature "$work/sig.der" "$work/tampered"
# Many signatures, so r or s with a high bit or a short encoding turn up and must still be 32 bytes each.
bad=0
for _ in $(seq 1 24); do
    t="$("$ci/asc-jwt.sh" --key "$key" --key-id ABC123DEFG --issuer-id "$issuer")"
    [[ "$(b64url_decode "${t##*.}" | wc -c | tr -d ' ')" == 64 ]] || bad=$(( bad + 1 ))
done
expect_eq "24 more signatures are 64 bytes" "0" "$bad"
now="$(date +%s)"
live_payload="$(b64url_decode "$(printf '%s' "$t" | cut -d. -f2)")"
expect_eq "default lifetime is 19 minutes" "1140" "$(printf '%s' "$live_payload" | jq '.exp - .iat')"
expect_ok "default iat is now" test "$(( $(printf '%s' "$live_payload" | jq .iat) - now ))" -le 5
expect_fail "lifetime over 20 minutes" "$ci/asc-jwt.sh" --key "$key" --key-id ABC123DEFG --issuer-id "$issuer" --lifetime 1201
expect_fail "bad key ID" "$ci/asc-jwt.sh" --key "$key" --key-id abc --issuer-id "$issuer"
if macos && command -v swift >/dev/null; then
    expect_eq "CryptoKit verifies the signature" "valid" "$(swift "$here/verify_jwt.swift" "$work/public.pem" "$token" 2>&1)"
    expect_eq "CryptoKit rejects a tampered token" "invalid" "$(swift "$here/verify_jwt.swift" "$work/public.pem" "${header}.${payload}X.${signature}" 2>&1 || true)"
else
    echo "  skip  CryptoKit cross-check (macOS only)"
fi

# --- asc-testflight.sh against a mock API ---------------------------------------------------------------
echo "asc-testflight.sh"
log="$work/requests.jsonl"
python3 -I "$here/mock_asc.py" "$log" "$work/port" &
mock_pid=$!
for _ in $(seq 1 50); do [[ -s "$work/port" ]] && break; sleep 0.1; done
port="$(cat "$work/port")"
printf 'Try recording with the phone folded.\nNon-ASCII: café ✓\n' > "$work/notes.txt"
output="$(ASC_API_BASE="http://127.0.0.1:$port" ASC_POLL_SECONDS=0 \
    DAYBOOK_ASC_KEY_PATH="$key" DAYBOOK_ASC_KEY_ID=ABC123DEFG DAYBOOK_ASC_ISSUER_ID="$issuer" \
    "$ci/asc-testflight.sh" --bundle-id local.daybook.phone --version 1.4.0 --build 1057 \
    --group "External testers" --notes-file "$work/notes.txt" --timeout 60 2>"$work/testflight.err")" || true
expect_eq "prints the build ID" "build_id=build-1" "$output"
expect_eq "request sequence" "GET /v1/apps
GET /v1/builds
GET /v1/builds
GET /v1/builds
GET /v1/builds/build-1/betaBuildLocalizations
POST /v1/betaBuildLocalizations
GET /v1/betaGroups
POST /v1/betaGroups/group-1/relationships/builds
POST /v1/betaAppReviewSubmissions" "$(jq -r '"\(.method) \(.path)"' "$log")"
expect_eq "app filter" "local.daybook.phone" "$(jq -r 'select(.path == "/v1/apps") | .query["filter[bundleId]"][0]' "$log")"
expect_eq "build filters" "6700000001 1057 1.4.0 IOS" \
    "$(jq -r 'select(.path == "/v1/builds") | .query | [.["filter[app]"][0], .["filter[version]"][0], .["filter[preReleaseVersion.version]"][0], .["filter[preReleaseVersion.platform]"][0]] | join(" ")' "$log" | head -1)"
expect_eq "What to Test body" "$(printf 'en-US|Try recording with the phone folded.\nNon-ASCII: café ✓|build-1')" \
    "$(jq -r 'select(.path == "/v1/betaBuildLocalizations") | .body.data | "\(.attributes.locale)|\(.attributes.whatsNew)|\(.relationships.build.data.id)"' "$log")"
expect_eq "group body" '[{"type":"builds","id":"build-1"}]' "$(jq -c 'select(.path | endswith("/relationships/builds")) | .body.data' "$log")"
expect_eq "review body" "build-1" "$(jq -r 'select(.path == "/v1/betaAppReviewSubmissions") | .body.data.relationships.build.data.id' "$log")"
expect_eq "JWT on every request" "ES256 ABC123DEFG appstoreconnect-v1 64" \
    "$(jq -r '"\(.jwt.header.alg) \(.jwt.header.kid) \(.jwt.payload.aud) \(.jwt.signature_bytes)"' "$log" | sort -u)"
expect_ok "reports export compliance" grep -q 'usesNonExemptEncryption=false' "$work/testflight.err"
: > "$log"
expect_fail "unknown group fails" env ASC_API_BASE="http://127.0.0.1:$port" ASC_POLL_SECONDS=0 \
    DAYBOOK_ASC_KEY_PATH="$key" DAYBOOK_ASC_KEY_ID=ABC123DEFG DAYBOOK_ASC_ISSUER_ID="$issuer" \
    "$ci/asc-testflight.sh" --bundle-id local.daybook.phone --version 1.4.0 --build 1057 --group "Nobody"
expect_fail "missing key fails" env -u DAYBOOK_ASC_KEY_PATH "$ci/asc-testflight.sh" --bundle-id x --version 1.0.0 --build 1

# --- release-notes.sh -----------------------------------------------------------------------------------
echo "release-notes.sh"
repo="$work/repo"
git init -q "$repo"
git_c() { git -C "$repo" -c user.name=Test -c user.email=test@example.com -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
git_c commit -q --allow-empty -m "Build the first version"
git_c tag v0.1.0
git_c commit -q --allow-empty -m "Add TestFlight uploads"
git_c commit -q --allow-empty -m "Fix the widget version"
git_c tag -a v0.2.0 -m "Second preview"
notes="$(cd "$repo" && "$ci/release-notes.sh" --ref v0.2.0)"
expect_ok "annotated message first" test "$(printf '%s\n' "$notes" | head -1)" = "Second preview"
expect_ok "changes since the previous tag" grep -q '^## Changes since v0.1.0$' <<< "$notes"
expect_eq "lists only the new commits" "2" "$(grep -c '^- ' <<< "$notes")"
text="$(cd "$repo" && "$ci/release-notes.sh" --ref v0.1.0 --format text)"
expect_eq "first release, text" "Changes:
- Build the first version" "$text"

# --- check-ios-archive.sh -------------------------------------------------------------------------------
echo "check-ios-archive.sh"
if macos; then
    make_archive() {
        # make_archive DIR ENCRYPTION(true|false|none) ICON(yes|no) WIDGET_BUILD [DEVICE_FAMILY JSON] [INTENT DESCRIPTION]
        local app="$1/Products/Applications/DaybookPhone.app"
        mkdir -p "$app/PlugIns/DaybookPhoneWidgets.appex"
        plutil -create xml1 "$app/Info.plist"
        plutil -insert CFBundleIdentifier -string local.daybook.phone "$app/Info.plist"
        plutil -insert CFBundleShortVersionString -string 1.4.0 "$app/Info.plist"
        plutil -insert CFBundleVersion -string 1057 "$app/Info.plist"
        [[ "$2" != none ]] && plutil -insert ITSAppUsesNonExemptEncryption -bool "$2" "$app/Info.plist"
        [[ "$3" == yes ]] && plutil -insert CFBundleIcons -json '{"CFBundlePrimaryIcon":{"CFBundleIconName":"AppIcon"}}' "$app/Info.plist"
        plutil -insert UIDeviceFamily -json "${5:-[1]}" "$app/Info.plist"
        # App Intent metadata as Xcode writes it: people-facing strings under "key", and Apple's own
        # protocol identifiers, which the check must ignore.
        mkdir -p "$app/Metadata.appintents"
        printf '{"actions":{"StartRecordingIntent":{"descriptionMetadata":{"descriptionText":{"key":"%s"}},"systemProtocols":["com.apple.link.systemProtocol.AudioRecording"]}}}' \
            "${6:-Records a conversation with the microphone.}" > "$app/Metadata.appintents/extract.actionsdata"
        local widget="$app/PlugIns/DaybookPhoneWidgets.appex/Info.plist"
        plutil -create xml1 "$widget"
        plutil -insert CFBundleIdentifier -string local.daybook.phone.widgets "$widget"
        plutil -insert CFBundleShortVersionString -string 1.4.0 "$widget"
        plutil -insert CFBundleVersion -string "$4" "$widget"
        return 0
    }
    make_archive "$work/good.xcarchive" false yes 1057
    expect_ok "a complete archive passes" "$ci/check-ios-archive.sh" "$work/good.xcarchive" --version 1.4.0 --build 1057
    make_archive "$work/no-key.xcarchive" none yes 1057
    expect_fail "missing ITSAppUsesNonExemptEncryption fails" "$ci/check-ios-archive.sh" "$work/no-key.xcarchive"
    make_archive "$work/true-key.xcarchive" true yes 1057
    expect_fail "ITSAppUsesNonExemptEncryption true fails" "$ci/check-ios-archive.sh" "$work/true-key.xcarchive"
    make_archive "$work/no-icon.xcarchive" false no 1057
    expect_fail "a missing app icon fails" "$ci/check-ios-archive.sh" "$work/no-icon.xcarchive"
    make_archive "$work/skew.xcarchive" false yes 1056
    expect_fail "an extension build number mismatch fails" "$ci/check-ios-archive.sh" "$work/skew.xcarchive" --build 1057
    expect_fail "a version mismatch fails" "$ci/check-ios-archive.sh" "$work/good.xcarchive" --version 1.5.0
    make_archive "$work/ipad.xcarchive" false yes 1057 '[1,2]'
    expect_fail "an archive that also runs on iPad fails" "$ci/check-ios-archive.sh" "$work/ipad.xcarchive"
    make_archive "$work/intent.xcarchive" false yes 1057 '[1]' "Records a conversation with the iPhone's microphone."
    expect_fail "an App Intent naming the iPhone fails" "$ci/check-ios-archive.sh" "$work/intent.xcarchive"
else
    echo "  skip  check-ios-archive.sh (macOS only)"
fi

# --- setup-github.sh dry run ----------------------------------------------------------------------------
echo "setup-github.sh"
mkdir -p "$work/bin"
printf '#!/bin/sh\necho "gh $*" >> "%s/gh-calls"\nexit 1\n' "$work" > "$work/bin/gh"
chmod +x "$work/bin/gh"
plan="$(PATH="$work/bin:$PATH" "$ci/setup-github.sh" --asc-key "$key" --asc-issuer-id "$issuer" \
    --testflight-group "External testers" --protect-tags 2>&1)"
expect_ok "dry run never calls gh" test ! -e "$work/gh-calls"
expect_ok "dry run says nothing changed" grep -q 'Nothing was changed' <<< "$plan"
for needle in "environments/release" "deployment-branch-policies" "gh secret set ASC_KEY_P8_BASE64 --env release" \
              "gh secret set ASC_ISSUER_ID --env release" "DAYBOOK_TEAM_ID --body 48H7CLBV8Y" \
              "DAYBOOK_TESTFLIGHT_GROUP --body External\\ testers" "default_workflow_permissions=read" "rulesets"; do
    expect_ok "plan includes $needle" grep -qF -- "$needle" <<< "$plan"
done
key_body="$(sed '1d;$d' "$key" | tr -d '\n' | cut -c1-24)"
expect_fail "plan never prints the key" grep -qF -- "$key_body" <<< "$plan"
expect_fail "rejects a bad issuer" "$ci/setup-github.sh" --asc-key "$key" --asc-issuer-id nope
expect_fail "rejects a missing key" "$ci/setup-github.sh" --asc-key "$work/none.p8" --asc-issuer-id "$issuer"

# --- build-ios.sh upload retry, with a stand-in xcodebuild --------------------------------------------
echo "build-ios.sh upload retry"
mkdir -p "$work/xcbin" "$work/upload.xcarchive"
cat > "$work/xcbin/xcodebuild" <<'STUB'
#!/bin/bash
n=$(( $(cat "$STUB_COUNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_COUNT"
if [[ "$STUB_MODE" == network && $n -lt 3 ]]; then echo "error: exportArchive The request timed out."; exit 70; fi
if [[ "$STUB_MODE" == rejected ]]; then echo "error: exportArchive Invalid bundle."; exit 70; fi
echo "** EXPORT SUCCEEDED **"
STUB
chmod +x "$work/xcbin/xcodebuild"
upload() {
    rm -f "$work/stub-count"
    PATH="$work/xcbin:$PATH" STUB_MODE="$1" STUB_COUNT="$work/stub-count" DAYBOOK_UPLOAD_RETRY_DELAY=0 \
        DAYBOOK_TEAM_ID=48H7CLBV8Y "$ci/../build-ios.sh" --export upload --archive-path "$work/upload.xcarchive" >/dev/null 2>&1
}
expect_ok "an upload that times out twice succeeds on the third try" upload network
expect_eq "it tried three times" 3 "$(cat "$work/stub-count")"
expect_fail "a rejected upload fails" upload rejected
expect_eq "without retrying" 1 "$(cat "$work/stub-count")"

echo
echo "$passed passed, $failed failed"
(( failed == 0 ))
