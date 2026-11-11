#!/bin/bash
# Tests for the release helpers in scripts/ci. Offline: nothing here talks to Apple or GitHub.
#
#   scripts/ci/tests/run-tests.sh [--require-all]
#
# --require-all fails the run if any group was skipped: CI's macOS job passes it, so the macOS-only
# groups (CryptoKit, archives, build scripts, keychain) can't silently drop out.
#
#   Python helpers        scripts/*.py and the mock compile with warnings as errors
#   version.sh            tag, branch, re-run, and rejection vectors
#   asc-jwt.sh            fixed header and payload vectors; the signature verified by openssl and, on
#                         macOS, by CryptoKit (an independent implementation)
#   asc-testflight.sh     the full request sequence against a local mock of the App Store Connect API, and no
#                         token left behind
#   asc-certificates.sh   the dry run and --revoke against the mock (fixture certificates), keeping the
#                         release pipeline's certificate
#   asc-development-certificate.sh
#                         making the pipeline's certificate against the mock, storing it with a fake gh
#   asc-profile.sh        the manually managed Developer ID profile against the mock, checked against a stand-in
#                         keychain's identity (macOS)
#   release-notes.sh      annotated and lightweight tags in a throwaway repository
#   check-ref.sh          tags on and off main, manual runs, in a throwaway clone
#   github-release.sh     draft, re-run, publish, and refusal to touch a published release (fake gh)
#   prune-caches.sh       which caches go and which stay, against a fake gh
#   xcresult-retries.sh   passes on retry and flaky iterations, from xcresulttool fixtures
#   own-warnings.sh       a warning in Sources/ or Apps/iOS/ fails, coloured or not; a dependency's or a test's doesn't
#   check-ios-archive.sh  synthetic archives: export compliance, icon, versions (macOS: needs plutil)
#   setup-github.sh       the dry run prints the plan and never calls gh
#   approve-release.sh    approves every waiting channel at once, rejects skipped ones, and checks first
#   select-xcode.sh       version and exact-build checks, SDKs, and the summary, with stand-in tools
#   secrets.sh            run/setup/cleanup with the API key, and a command that sees no raw secret; on macOS, the
#                         .p12 keychain (Developer ID and development) with a stand-in security that checks no
#                         password reaches a command line
#   build-ios.sh          the upload retry, package pinning, the API key's guard, archive and export calls, and
#                         --test's simulator, with stand-in Xcode tools (macOS)
#   build-app.sh          the xcodebuild calls and export options, with stand-in Xcode tools in a copy of
#                         the repository (macOS)
#   check-mac-app.sh      bundle IDs, App Sandbox entitlements, and migration manifests of each kind of build,
#                         on stand-in apps signed ad hoc with the repository's entitlements files (macOS)
#   package-mac.sh        version and build checks, ZIP, DMG (or none without this team's Developer ID identity),
#                         checksums, notarization waits, pending submissions, and notary-resume.sh, with stand-in
#                         tools (macOS)
#   app icon              Resources/Daybook.icon has every layer it names, and both apps build it as their icon
#   pipelines             no script reads a tool's output with a reader that stops early (head, grep -q, awk exit)
# Runs on macOS (bash 3.2) and Linux.
set -euo pipefail

require_all=0
case "${1-}" in
    --require-all) require_all=1 ;;
    "") ;;
    *) echo "usage: $0 [--require-all]" >&2; exit 2 ;;
esac

here="$(cd "$(dirname "$0")" && pwd)"
ci="$(cd "$here/.." && pwd)"
work="$(mktemp -d)"
mock_pid=""
cleanup() {
    if [[ -n "$mock_pid" ]]; then
        kill "$mock_pid" 2>/dev/null || true
        wait "$mock_pid" 2>/dev/null || true
    fi
    /bin/rm -rf "${work:?}"
}
trap cleanup EXIT

passed=0
failed=0
skipped=0
skip() { skipped=$(( skipped + 1 )); echo "  skip  $1"; }
pass() { passed=$(( passed + 1 )); echo "  ok    $1"; }
flunk() { failed=$(( failed + 1 )); echo "  FAIL  $1" >&2; }
expect_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else flunk "$1: expected [$2], got [$3]"; fi; }
expect_ok() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else flunk "$name"; fi; }
expect_fail() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then flunk "$name (succeeded)"; else pass "$name"; fi; }
b64url_decode() { local s="$1"; while (( ${#s} % 4 )); do s="$s="; done; printf '%s' "$s" | tr '_-' '/+' | base64 -d; }
macos() { [[ "$(uname)" == Darwin ]]; }

# Stand-ins for Xcode's tools, security, and curl (stub_tool.sh). Every test that runs a script which
# could reach the keychain, Xcode, or the network puts these first on PATH.
stubs="$work/stubs"
mkdir -p "$stubs"
for tool in xcodebuild xcodegen xcrun codesign ditto hdiutil spctl security curl swift; do
    cp "$here/stub_tool.sh" "$stubs/$tool"
    chmod +x "$stubs/$tool"
done

# --- Python helpers ------------------------------------------------------------------------------------
echo "Python helpers"
for script in "$ci"/../*.py "$here"/*.py; do
    # Compiled in memory with warnings as errors (an invalid escape sequence is a SyntaxWarning), so no
    # __pycache__ is written.
    expect_ok "$(basename "$script") compiles cleanly" python3 -I -W error -c \
        'import pathlib, sys; compile(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"), sys.argv[1], "exec")' "$script"
done
expect_ok "model-revision.py --help runs offline" python3 -I "$ci/../model-revision.py" --help

# --- version.sh ----------------------------------------------------------------------------------------
echo "version.sh"
expect_eq "tag" "marketing_version=1.4.0
build_number=1057
build_base=1057
build_candidates=1057
tag=v1.4.0
is_tag=true
prerelease=false" "$("$ci/version.sh" --ref refs/tags/v1.4.0 --run-number 57)"
expect_eq "prerelease tag" "1.4.0 true" \
    "$("$ci/version.sh" --ref refs/tags/v1.4.0-rc.1 --run-number 1 | awk -F= '/^marketing_version|^prerelease/ {printf "%s%s", sep, $2; sep=" "}')"
expect_eq "re-run attempt" "build_number=1057.2" "$("$ci/version.sh" --ref refs/tags/v1.4.0 --run-number 57 --run-attempt 2 | grep build_number)"
expect_eq "third attempt: base and every number so far" "build_number=1057.3 build_base=1057 build_candidates=1057 1057.2 1057.3" \
    "$("$ci/version.sh" --ref refs/tags/v1.4.0 --run-number 57 --run-attempt 3 | grep '^build_' | paste -sd ' ' -)"
expect_fail "absurd attempt" "$ci/version.sh" --ref refs/tags/v1.4.0 --run-number 57 --run-attempt 101
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
    skip "CryptoKit cross-check (macOS only)"
fi

# --- asc-testflight.sh against a mock API ---------------------------------------------------------------
echo "asc-testflight.sh"
log="$work/requests.jsonl"
python3 -I "$here/mock_asc.py" "$log" "$work/port" &
mock_pid=$!
for _ in $(seq 1 50); do [[ -s "$work/port" ]] && break; sleep 0.1; done
port="$(cat "$work/port")"
printf 'Try recording with the phone folded.\nNon-ASCII: café ✓\n' > "$work/notes.txt"
# Its own temporary directory, to see that the token's header file doesn't outlive the script.
mkdir -p "$work/testflight-tmp"
output="$(TMPDIR="$work/testflight-tmp" ASC_API_BASE="http://127.0.0.1:$port" ASC_POLL_SECONDS=0 \
    DAYBOOK_ASC_KEY_PATH="$key" DAYBOOK_ASC_KEY_ID=ABC123DEFG DAYBOOK_ASC_ISSUER_ID="$issuer" \
    "$ci/asc-testflight.sh" --bundle-id local.daybook --version 1.4.0 --build 1057 \
    --group "External testers" --notes-file "$work/notes.txt" --timeout 60 2>"$work/testflight.err")" || true
expect_eq "prints the build ID" "build_id=build-1" "$output"
expect_eq "leaves no token behind" "" "$(ls -A "$work/testflight-tmp")"
expect_eq "request sequence" "GET /v1/apps
GET /v1/builds
GET /v1/builds
GET /v1/builds
GET /v1/builds/build-1/betaBuildLocalizations
POST /v1/betaBuildLocalizations
GET /v1/betaGroups
POST /v1/betaGroups/group-1/relationships/builds
POST /v1/betaAppReviewSubmissions" "$(jq -r '"\(.method) \(.path)"' "$log")"
expect_eq "app filter" "local.daybook" "$(jq -r 'select(.path == "/v1/apps") | .query["filter[bundleId]"][0]' "$log")"
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
expect_ok "an internal group with every build needs no assignment" env ASC_API_BASE="http://127.0.0.1:$port" ASC_POLL_SECONDS=0 \
    DAYBOOK_ASC_KEY_PATH="$key" DAYBOOK_ASC_KEY_ID=ABC123DEFG DAYBOOK_ASC_ISSUER_ID="$issuer" \
    "$ci/asc-testflight.sh" --bundle-id local.daybook --version 1.4.0 --build 1057 --group "Daybook Internal"
expect_eq "nothing is added or submitted for review" "" \
    "$(jq -r 'select(.method == "POST" and (.path | test("relationships/builds|betaAppReviewSubmissions"))) | .path' "$log")"
: > "$log"
expect_fail "unknown group fails" env TMPDIR="$work/testflight-tmp" ASC_API_BASE="http://127.0.0.1:$port" ASC_POLL_SECONDS=0 \
    DAYBOOK_ASC_KEY_PATH="$key" DAYBOOK_ASC_KEY_ID=ABC123DEFG DAYBOOK_ASC_ISSUER_ID="$issuer" \
    "$ci/asc-testflight.sh" --bundle-id local.daybook --version 1.4.0 --build 1057 --group "Nobody"
expect_eq "and leaves no token behind either" "" "$(ls -A "$work/testflight-tmp")"
expect_fail "missing key fails" env -u DAYBOOK_ASC_KEY_PATH "$ci/asc-testflight.sh" --bundle-id x --version 1.0.0 --build 1
: > "$log"
expect_ok "the Mac's build in the same app record" env ASC_API_BASE="http://127.0.0.1:$port" ASC_POLL_SECONDS=0 \
    DAYBOOK_ASC_KEY_PATH="$key" DAYBOOK_ASC_KEY_ID=ABC123DEFG DAYBOOK_ASC_ISSUER_ID="$issuer" \
    "$ci/asc-testflight.sh" --bundle-id local.daybook --version 1.4.0 --build 1057 --platform MAC_OS
expect_eq "is looked for among the macOS builds" "MAC_OS" \
    "$(jq -r 'select(.path == "/v1/builds") | .query["filter[preReleaseVersion.platform]"][0]' "$log" | sort -u)"
expect_fail "--platform is IOS or MAC_OS" env DAYBOOK_ASC_KEY_PATH="$key" DAYBOOK_ASC_KEY_ID=ABC123DEFG DAYBOOK_ASC_ISSUER_ID="$issuer" \
    "$ci/asc-testflight.sh" --bundle-id local.daybook --version 1.4.0 --build 1057 --platform VISION_OS
find_build() {
    ASC_API_BASE="http://127.0.0.1:$port" DAYBOOK_ASC_KEY_PATH="$key" DAYBOOK_ASC_KEY_ID=ABC123DEFG DAYBOOK_ASC_ISSUER_ID="$issuer" \
        "$ci/asc-testflight.sh" --bundle-id local.daybook --version 1.4.0 "$@" 2>"$work/find.err"
}
: > "$log"
expect_eq "an earlier attempt's upload is found; a failed one is skipped" "found=2001" \
    "$(find_build --find-build "2001 2001.2 2001.3" --uploaded-after 2026-10-24T20:11:08Z)"
expect_eq "one lookup for every candidate" "GET /v1/apps|GET /v1/builds 2001,2001.2,2001.3 1.4.0" \
    "$(jq -r '"\(.method) \(.path)\(if .path == "/v1/builds" then " \(.query["filter[version]"][0]) \(.query["filter[preReleaseVersion.version]"][0])" else "" end)"' "$log" | paste -sd '|' -)"
expect_eq "nothing uploaded yet" "found=" "$(find_build --find-build "2002")"
expect_fail "a build uploaded before the run started is a collision" find_build --find-build "3001" --uploaded-after 2026-10-24T20:11:08Z
expect_ok "the collision says to raise the offset" grep -q "Raise DAYBOOK_BUILD_NUMBER_OFFSET" "$work/find.err"
expect_eq "without a start time it's simply found" "found=3001" "$(find_build --find-build "3001")"
expect_fail "find mode rejects a malformed list" find_build --find-build "1057;rm"
expect_fail "find mode rejects a malformed time" find_build --find-build "2001" --uploaded-after yesterday

# --- asc-certificates.sh against the mock ----------------------------------------------------------------
echo "asc-certificates.sh"
pipeline_certificate=""
certificates() {
    : > "$log"
    ASC_API_BASE="http://127.0.0.1:$port" DAYBOOK_NOW=1793000000 DAYBOOK_DEVELOPMENT_CERTIFICATE_ID="$pipeline_certificate" \
        DAYBOOK_ASC_KEY_PATH="$key" DAYBOOK_ASC_KEY_ID=ABC123DEFG DAYBOOK_ASC_ISSUER_ID="$issuer" \
        "$ci/../asc-certificates.sh" "$@" > "$work/certificates.out" 2>&1
}
expect_ok "the dry run lists them" certificates
expect_eq "only GETs, and both pages" "GET /v1/certificates GET /v1/certificates" "$(jq -r '"\(.method) \(.path)"' "$log" | paste -sd ' ' -)"
expect_eq "asks for development certificates only" "DEVELOPMENT,IOS_DEVELOPMENT,MAC_APP_DEVELOPMENT" \
    "$(jq -r 'select(.query["filter[certificateType]"]) | .query["filter[certificateType]"][0]' "$log")"
expect_eq "the pipeline's three, two of them old" "cert-fresh keep|cert-old revoke|cert-old-mac revoke" \
    "$(awk '$1 ~ /^cert-/ {print $1, $NF}' "$work/certificates.out" | paste -sd '|' -)"
expect_ok "and says nothing changed" grep -q "Dry run: nothing was changed" "$work/certificates.out"
expect_ok "--revoke" certificates --revoke
expect_eq "revokes only the old ones" "DELETE /v1/certificates/cert-old|DELETE /v1/certificates/cert-old-mac" \
    "$(jq -r 'select(.method == "DELETE") | "\(.method) \(.path)"' "$log" | paste -sd '|' -)"
expect_ok "--older-than 200 --revoke" certificates --older-than 200 --revoke
expect_eq "keeps everything newer" "DELETE /v1/certificates/cert-old-mac" "$(jq -r 'select(.method == "DELETE") | "\(.method) \(.path)"' "$log")"
expect_fail "a bad age is refused" certificates --older-than soon
pipeline_certificate=cert-old
expect_ok "with the release pipeline's certificate" certificates --revoke
expect_eq "it's kept, however old" "cert-fresh keep|cert-old pipeline)|cert-old-mac revoked" \
    "$(awk '$1 ~ /^cert-/ {print $1, $NF}' "$work/certificates.out" | paste -sd '|' -)"
expect_eq "(only the other old one goes)" "DELETE /v1/certificates/cert-old-mac" "$(jq -r 'select(.method == "DELETE") | "\(.method) \(.path)"' "$log")"
pipeline_certificate=""
expect_ok "--keep does the same" certificates --keep cert-old-mac --revoke
expect_eq "(keeping that one)" "DELETE /v1/certificates/cert-old" "$(jq -r 'select(.method == "DELETE") | "\(.method) \(.path)"' "$log")"

# --- asc-development-certificate.sh against the mock, a fake gh, and a stand-in security -----------------
echo "asc-development-certificate.sh"
mkdir -p "$work/devcert-bin" "$work/devcert-gh"
cp "$here/fake_gh.sh" "$work/devcert-bin/gh"
cp "$here/stub_tool.sh" "$work/devcert-bin/security"
chmod +x "$work/devcert-bin/gh" "$work/devcert-bin/security"
# development_certificate IDENTITY [ARGS...]: IDENTITY 1 means the .p12 imports with an Apple Development identity.
development_certificate() {
    local identity="$1"; shift
    : > "$log"
    rm -rf "$work/devcert-gh/secrets"
    PATH="$work/devcert-bin:$PATH" GH_STATE="$work/devcert-gh" STUB_LOG="$work/devcert-stub.log" \
        STUB_DEVELOPMENT_IDENTITY="$identity" ASC_API_BASE="http://127.0.0.1:$port" \
        DAYBOOK_ASC_KEY_PATH="$key" DAYBOOK_ASC_KEY_ID=ABC123DEFG DAYBOOK_ASC_ISSUER_ID="$issuer" \
        "$ci/../asc-development-certificate.sh" "$@" > "$work/devcert.out" 2>&1
}
: > "$work/devcert-gh/calls"
expect_ok "makes it and stores it" development_certificate 1
expect_eq "one Apple Development certificate, from a CSR" "POST DEVELOPMENT -----BEGIN CERTIFICATE REQUEST-----" \
    "$(jq -r 'select(.method == "POST") | "\(.method) \(.body.data.attributes.certificateType) \(.body.data.attributes.csrContent | split("\n")[0])"' "$log")"
secrets="$work/devcert-gh/secrets/Mac download"
for channel in "iOS TestFlight" "Mac TestFlight" "Mac download"; do
    expect_ok "both secrets in '$channel'" test -s "$work/devcert-gh/secrets/$channel/DEVELOPMENT_P12_BASE64" \
        -a -s "$work/devcert-gh/secrets/$channel/DEVELOPMENT_P12_PASSWORD"
done
expect_ok "the same .p12 in each" cmp -s "$work/devcert-gh/secrets/iOS TestFlight/DEVELOPMENT_P12_BASE64" "$secrets/DEVELOPMENT_P12_BASE64"
# What the script said, when it stopped before storing them (a runner once failed here without a trace).
[[ -s "$secrets/DEVELOPMENT_P12_BASE64" ]] || sed 's/^/        /' "$work/devcert.out"
base64 -d < "$secrets/DEVELOPMENT_P12_BASE64" > "$work/development.p12"
expect_ok "the .p12 holds the certificate" sh -c "openssl pkcs12 -in '$work/development.p12' -nokeys -passin 'file:$secrets/DEVELOPMENT_P12_PASSWORD' 2>/dev/null | grep -q 'Apple Development: Created via API'"
expect_ok "and its key" sh -c "openssl pkcs12 -in '$work/development.p12' -nocerts -nodes -passin 'file:$secrets/DEVELOPMENT_P12_PASSWORD' 2>/dev/null | grep -q 'PRIVATE KEY'"
expect_eq "the certificate's ID in the repository variable" "cert-new" "$(cat "$work/devcert-gh/variables/DAYBOOK_DEVELOPMENT_CERTIFICATE_ID")"
expect_eq "no password on any gh command line" "" "$(grep -F "$(cat "$secrets/DEVELOPMENT_P12_PASSWORD")" "$work/devcert-gh/calls" || true)"
expect_eq "nor on security's" "" "$(grep '^security ' "$work/devcert-stub.log" | grep -F "$(cat "$secrets/DEVELOPMENT_P12_PASSWORD")" || true)"
expect_eq "and nothing revoked" "" "$(jq -r 'select(.method == "DELETE") | .path' "$log")"
expect_fail "a .p12 macOS can't use fails" development_certificate 0
expect_eq "and revokes the new certificate" "DELETE /v1/certificates/cert-new" "$(jq -r 'select(.method == "DELETE") | "\(.method) \(.path)"' "$log")"
expect_ok "storing nothing" test ! -e "$work/devcert-gh/secrets"
expect_ok "--environment stores it in that one alone" development_certificate 1 --environment "Mac TestFlight"
expect_eq "(only there)" "Mac TestFlight" "$(ls "$work/devcert-gh/secrets")"

# --- asc-profile.sh against the mock and a stand-in security ---------------------------------------------
echo "asc-profile.sh"
if macos; then
    # The mock's profiles hold this certificate; the stand-in keychain's Developer ID identity is its SHA-1.
    certificate_sha="$(printf 'Daybook test Developer ID Application certificate' | shasum -a 1 | awk '{ print toupper($1) }')"
    # asc_profile IDENTITY SHA [ARGS...]: IDENTITY 1 puts a Developer ID identity with certificate SHA-1 SHA in the
    # stand-in keychain, which also prints its count line after it, as security does.
    asc_profile() {
        local identity="$1" sha="$2"
        shift 2
        : > "$log"
        rm -rf "$work/profiles"
        PATH="$work/devcert-bin:$PATH" STUB_LOG="$work/profile-stub.log" STUB_IDENTITY="$identity" STUB_IDENTITY_SHA="$sha" \
            ASC_API_BASE="http://127.0.0.1:$port" DAYBOOK_ASC_KEY_PATH="$key" DAYBOOK_ASC_KEY_ID=ABC123DEFG \
            DAYBOOK_ASC_ISSUER_ID="$issuer" "$ci/asc-profile.sh" --type MAC_APP_DIRECT --install-dir "$work/profiles" "$@" \
            2>"$work/profile.err"
    }
    expect_eq "the active, manually managed Developer ID profile, over Xcode's newer one" "01234567-89AB-CDEF-0123-456789ABCDEF" \
        "$(asc_profile 1 "$certificate_sha" --bundle-id local.daybook --keychain "$work/signing.keychain-db")"
    expect_ok "installed under its UUID" test -s "$work/profiles/01234567-89AB-CDEF-0123-456789ABCDEF.provisionprofile"
    expect_eq "only reads" "GET /v1/bundleIds|GET /v1/bundleIds/bundle-1/profiles" \
        "$(jq -r '"\(.method) \(.path)"' "$log" | paste -sd '|' -)"
    expect_fail "a profile without the keychain identity's certificate fails" \
        asc_profile 1 0123456789ABCDEF0123456789ABCDEF01234567 --bundle-id local.daybook --keychain "$work/signing.keychain-db"
    expect_ok "and says so" grep -q "doesn't contain the certificate of the Developer ID identity" "$work/profile.err"
    expect_fail "a keychain without a Developer ID identity fails" \
        asc_profile 0 "" --bundle-id local.daybook --keychain "$work/signing.keychain-db"
    expect_ok "(none in it)" grep -q "no Developer ID Application identity in" "$work/profile.err"
    expect_fail "an unknown bundle ID fails" asc_profile 0 "" --bundle-id local.daybook.unknown
    expect_ok "naming it" grep -q "no bundle ID local.daybook.unknown" "$work/profile.err"
else
    skip "asc-profile.sh (macOS only)"
fi

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

# --- check-ref.sh ---------------------------------------------------------------------------------------
echo "check-ref.sh"
upstream="$work/upstream"
git init -q -b main "$upstream"
git_u() { git -C "$upstream" -c user.name=Test -c user.email=test@example.com -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
git_u commit -q --allow-empty -m "Release one"
git_u tag -a v1.0.0 -m "One"
git_u checkout -q -b side
git_u commit -q --allow-empty -m "Unreviewed change"
git_u tag -a v1.0.1 -m "Off main"
git_u checkout -q main
git_u commit -q --allow-empty -m "Release two"
git clone -q "$upstream" "$work/checkout"
on_main="$(git -C "$work/checkout" rev-parse 'v1.0.0^{commit}')"
off_main="$(git -C "$work/checkout" rev-parse 'v1.0.1^{commit}')"
check_ref() { (cd "$work/checkout" && "$ci/check-ref.sh" "$@"); }
expect_ok "a tag on main passes" check_ref --event push --ref refs/tags/v1.0.0 --sha "$on_main"
expect_ok "an annotated tag object peels to its commit" check_ref --event push --ref refs/tags/v1.0.0 --sha "$(git -C "$work/checkout" rev-parse v1.0.0)"
expect_fail "a tag off main fails" check_ref --event push --ref refs/tags/v1.0.1 --sha "$off_main"
expect_ok "the refusal names the commit" grep -q "isn't on main" <<< "$(check_ref --event push --ref refs/tags/v1.0.1 --sha "$off_main" 2>&1 || true)"
expect_fail "a manual run on a tag off main fails" check_ref --event workflow_dispatch --ref refs/tags/v1.0.1 --sha "$off_main"
expect_ok "a manual run from main passes" check_ref --event workflow_dispatch --ref refs/heads/main --sha "$on_main"
expect_fail "a push to main doesn't release" check_ref --event push --ref refs/heads/main --sha "$on_main"
expect_fail "a manual run from another branch fails" check_ref --event workflow_dispatch --ref refs/heads/side --sha "$off_main"
expect_fail "an unknown commit fails" check_ref --event push --ref refs/tags/v1.0.0 --sha 0123456789abcdef0123456789abcdef01234567

# --- github-release.sh against a fake gh ---------------------------------------------------------------
echo "github-release.sh"
mkdir -p "$work/ghbin" "$work/gh" "$work/out"
cp "$here/fake_gh.sh" "$work/ghbin/gh"
chmod +x "$work/ghbin/gh"
echo missing > "$work/gh/state"
printf 'zip\n' > "$work/out/Daybook-1.4.0-macOS-arm64.zip"
printf 'dmg\n' > "$work/out/Daybook-1.4.0-macOS-arm64.dmg"
printf 'sums\n' > "$work/out/SHA256SUMS.txt"
printf 'Notes\n' > "$work/release-notes.md"
release() { PATH="$work/ghbin:$PATH" GH_STATE="$work/gh" "$ci/github-release.sh" "$@"; }
draft() { release draft --repo example/daybook --tag v1.4.0 --title "Daybook 1.4.0" --notes-file "$work/release-notes.md" "$@"; }
assets() { sort "$work/gh/assets" | paste -sd ' ' -; }
expect_ok "the first run creates a draft" draft --prerelease false "$work"/out/*
expect_eq "a draft with every file" "draft|Daybook-1.4.0-macOS-arm64.dmg Daybook-1.4.0-macOS-arm64.zip SHA256SUMS.txt" \
    "$(cat "$work/gh/state")|$(assets)"
expect_ok "created as a draft of the existing tag" grep -qE -- '^release create v1.4.0 .*--draft.*--verify-tag' "$work/gh/calls"
rm "$work/out/Daybook-1.4.0-macOS-arm64.dmg"
expect_ok "a re-run updates the draft" draft --prerelease true "$work"/out/*
expect_eq "the DMG it no longer makes is gone" "Daybook-1.4.0-macOS-arm64.zip SHA256SUMS.txt" "$(assets)"
expect_ok "the files are replaced in the draft" grep -qE -- '^release upload v1.4.0 .*--clobber' "$work/gh/calls"
expect_eq "title and prerelease set again" "Daybook 1.4.0 true" "$(cat "$work/gh/title") $(cat "$work/gh/prerelease")"
expect_eq "publishing prints the URL" "https://github.com/example/daybook/releases/tag/v1.4.0" \
    "$(release publish --repo example/daybook --tag v1.4.0 2>/dev/null)"
expect_eq "published" "published" "$(cat "$work/gh/state")"
uploads="$(grep -c '^release upload' "$work/gh/calls")"
expect_fail "a published release is never replaced" draft --prerelease false "$work"/out/*
expect_eq "nothing was uploaded to it" "$uploads" "$(grep -c '^release upload' "$work/gh/calls")"
expect_ok "publishing again changes nothing" release publish --repo example/daybook --tag v1.4.0
echo missing > "$work/gh/state"
expect_fail "there's nothing to publish without a draft" release publish --repo example/daybook --tag v1.4.0
expect_fail "a branch isn't a release tag" release publish --repo example/daybook --tag main
expect_fail "a draft needs its files" draft --prerelease false "$work/out/none.zip"

# --- prune-caches.sh against a fake gh ------------------------------------------------------------------
echo "prune-caches.sh"
hash_a="$(printf 'a%.0s' $(seq 64))"
hash_b="$(printf 'b%.0s' $(seq 64))"
hash_c="$(printf 'c%.0s' $(seq 64))"
printf '%s\t%s\t%s\n' \
    1 "swiftpm-macOS-27A9275-$hash_a" refs/heads/main \
    2 "swiftpm-macOS-27A9275-$hash_b" refs/heads/main \
    3 "swiftpm-macOS-27A9275-$hash_c" refs/heads/main \
    4 "mac-dd-macOS-27A9275-Debug-$hash_a" refs/heads/main \
    5 "mac-dd-macOS-27A9275-Release-$hash_a" refs/heads/main \
    6 "ios-dd-macOS-27A9275-$hash_a" refs/heads/main \
    7 "swiftpm-macOS-27A9275-$hash_a" refs/pull/9/merge > "$work/gh/caches"
prune() { PATH="$work/ghbin:$PATH" GH_STATE="$work/gh" "$ci/prune-caches.sh" --repo example/daybook "$@" > "$work/prune.out" 2>&1; }
cache_ids() { cut -f1 "$work/gh/caches" | paste -sd ' ' -; }
expect_ok "prunes the families this run saved" prune "swiftpm-macOS-27A9275-$hash_c" "mac-dd-macOS-27A9275-Debug-$hash_b"
expect_eq "older swiftpm caches go; another ref's, other families', and an unsaved key's family stay" "3 4 5 6 7" "$(cache_ids)"
expect_ok "says what it left alone" grep -q "mac-dd-macOS-27A9275-Debug-$hash_b isn't saved on refs/heads/main" "$work/prune.out"
expect_ok "nothing to do is fine" prune "ios-dd-macOS-27A9275-$hash_a"
expect_eq "(unchanged)" "3 4 5 6 7" "$(cache_ids)"
expect_fail "a key without a hash is refused" prune "swiftpm-macOS-27A9275-"

# --- xcresult-retries.sh on xcresulttool output (fixtures from real runs, names changed) -----------------
echo "xcresult-retries.sh"
fixtures="$here/fixtures"
: > "$work/xc-summary"
retried="$(GITHUB_STEP_SUMMARY="$work/xc-summary" "$ci/xcresult-retries.sh" --json "$fixtures/xcresult-retried.json")"
expect_eq "a pass on retry is a warning" "::warning title=Passed on retry::PhoneRecorderTests/testCrashRecoveryProducesAudioNotesAndBookmarks() failed, then passed on a retry (Failed, Passed)" \
    "$(printf '%s\n' "$retried" | grep '^::')"
expect_ok "and in the summary" grep -qF "Passed on retry: \`PhoneRecorderTests/testCrashRecoveryProducesAudioNotesAndBookmarks()\`" "$work/xc-summary"
expect_eq "a test that passed every attempt isn't" "0" "$(printf '%s\n' "$retried" | grep -c 'testRealTimeSegments' || true)"
expect_eq "mixed iterations are flaky" "::warning title=Flaky test::PhoneRecorderTests/testCrashRecoveryProducesAudioNotesAndBookmarks() passed some attempts and failed others (Failed, Passed, Passed)" \
    "$("$ci/xcresult-retries.sh" --json "$fixtures/xcresult-iterations.json" | grep '^::')"
jq 'walk(if type == "object" and .nodeType == "Repetition" then .result = "Passed" else . end)' "$fixtures/xcresult-retried.json" > "$work/all-passed.json"
expect_eq "all passing: no warnings" "" "$("$ci/xcresult-retries.sh" --json "$work/all-passed.json" | grep '^::' || true)"
expect_ok "no bundle (the run stopped early) is fine" "$ci/xcresult-retries.sh" "$work/none.xcresult"

# --- own-warnings.sh on build logs ------------------------------------------------------------------------
echo "own-warnings.sh"
esc=$'\x1b'
{
    echo "[12/40] Compiling Daybook CallPrompt.swift"
    echo "/w/repo/Sources/Daybook/UI/CallPrompt.swift:60:26: ${esc}[1;33mwarning: ${esc}[1;39mimmutable value 'call' was never used${esc}[0;0m"
    echo "  |  \`- warning: immutable value 'call' was never used"
    echo "/w/repo/Sources/Daybook/UI/CallPrompt.swift:60:26: ${esc}[1;33mwarning: ${esc}[1;39mimmutable value 'call' was never used${esc}[0;0m"
    echo "/w/repo/.build/checkouts/mlx-swift/Source/Cmlx/mlx/mlx/array.h:12:3: warning: unused variable 'x' [-Wunused-variable]"
    echo "/w/repo/Tests/DaybookCoreTests/SpeakerProfileTests.swift:125:13: warning: variable 'foreign' was never mutated"
    echo "/w/DerivedData/SourcePackages/checkouts/swift-transformers/Sources/Hub/Hub.swift:3:1: warning: deprecated"
} > "$work/warnings.log"
own="$("$ci/own-warnings.sh" "$work/warnings.log" || true)"
expect_fail "a warning in Sources/ fails" "$ci/own-warnings.sh" "$work/warnings.log"
expect_eq "named once, without colour codes" "/w/repo/Sources/Daybook/UI/CallPrompt.swift:60:26: warning: immutable value 'call' was never used" \
    "$(printf '%s\n' "$own" | grep -v '^::' || true)"
grep -v 'CallPrompt' "$work/warnings.log" > "$work/dependencies.log"
expect_ok "a dependency's or a test's doesn't" "$ci/own-warnings.sh" "$work/dependencies.log"
echo "Apps/iOS/DaybookPhone/App/PhoneAppModel.swift:9:5: warning: unused" >> "$work/dependencies.log"
expect_fail "the iPhone app's fails too, with a relative path" "$ci/own-warnings.sh" "$work/dependencies.log"
expect_fail "a missing log is an error" "$ci/own-warnings.sh" "$work/none.log"

# --- check-ios-archive.sh -------------------------------------------------------------------------------
echo "check-ios-archive.sh"
if macos; then
    make_archive() {
        # make_archive DIR ENCRYPTION(true|false|none) ICON(yes|no) WIDGET_BUILD [DEVICE_FAMILY JSON] [INTENT DESCRIPTION]
        local app="$1/Products/Applications/DaybookPhone.app"
        mkdir -p "$app/PlugIns/DaybookPhoneWidgets.appex"
        plutil -create xml1 "$app/Info.plist"
        plutil -insert CFBundleIdentifier -string "${STUB_APP_ID:-local.daybook}" "$app/Info.plist"
        plutil -insert CFBundleShortVersionString -string 1.4.0 "$app/Info.plist"
        plutil -insert CFBundleVersion -string 1057 "$app/Info.plist"
        [[ "$2" != none ]] && plutil -insert ITSAppUsesNonExemptEncryption -bool "$2" "$app/Info.plist"
        [[ "$3" == yes ]] && plutil -insert CFBundleIcons -json '{"CFBundlePrimaryIcon":{"CFBundleIconName":"Daybook"}}' "$app/Info.plist"
        plutil -insert UIDeviceFamily -json "${5:-[1]}" "$app/Info.plist"
        # App Intent metadata as Xcode writes it: people-facing strings under "key", and Apple's own
        # protocol identifiers, which the check must ignore.
        mkdir -p "$app/Metadata.appintents"
        printf '{"actions":{"StartRecordingIntent":{"descriptionMetadata":{"descriptionText":{"key":"%s"}},"systemProtocols":["com.apple.link.systemProtocol.AudioRecording"]}}}' \
            "${6:-Records a conversation with the microphone.}" > "$app/Metadata.appintents/extract.actionsdata"
        local widget="$app/PlugIns/DaybookPhoneWidgets.appex/Info.plist"
        plutil -create xml1 "$widget"
        plutil -insert CFBundleIdentifier -string "${STUB_APP_ID:-local.daybook}.widgets" "$widget"
        plutil -insert CFBundleShortVersionString -string 1.4.0 "$widget"
        plutil -insert CFBundleVersion -string "$4" "$widget"
        return 0
    }
    make_archive "$work/good.xcarchive" false yes 1057
    expect_ok "a complete archive passes" "$ci/check-ios-archive.sh" "$work/good.xcarchive" --version 1.4.0 --build 1057
    STUB_APP_ID=local.daybook.phone make_archive "$work/earlier-id.xcarchive" false yes 1057
    expect_fail "an archive under the earlier bundle ID fails" "$ci/check-ios-archive.sh" "$work/earlier-id.xcarchive"
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
    skip "check-ios-archive.sh (macOS only)"
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
for needle in "environments/iOS%20TestFlight" "environments/Mac%20TestFlight" "environments/Mac%20download" \
              "deployment-branch-policies" "gh secret set ASC_KEY_P8_BASE64 --env iOS\\ TestFlight" \
              "gh secret set ASC_KEY_P8_BASE64 --env Mac\\ TestFlight" "gh secret set ASC_ISSUER_ID --env Mac\\ download" \
              "DAYBOOK_TEAM_ID --body 48H7CLBV8Y" \
              "DAYBOOK_TESTFLIGHT_GROUP --body External\\ testers" "default_workflow_permissions=read" "rulesets" \
              "sha_pinning_required=true" "secret_scanning_push_protection" "automated-security-fixes"; do
    expect_ok "plan includes $needle" grep -qF -- "$needle" <<< "$plan"
done
key_body="$(sed '1d;$d' "$key" | tr -d '\n' | cut -c1-24)"
expect_fail "plan never prints the key" grep -qF -- "$key_body" <<< "$plan"
expect_fail "no Developer ID identity without --developer-id-p12" grep -qF DEVELOPER_ID_P12 <<< "$plan"
p12_plan="$(PATH="$work/bin:$PATH" "$ci/setup-github.sh" --asc-key "$key" --asc-issuer-id "$issuer" --developer-id-p12 "$key" 2>&1)"
expect_eq "the Developer ID identity goes to 'Mac download'" 2 "$(grep -cF -- '--env Mac\ download' <<< "$(grep -F DEVELOPER_ID_P12 <<< "$p12_plan")")"
expect_eq "and nowhere else" 2 "$(grep -cF 'gh secret set DEVELOPER_ID_P12' <<< "$p12_plan")"
one_plan="$(PATH="$work/bin:$PATH" "$ci/setup-github.sh" --asc-key "$key" --asc-issuer-id "$issuer" --environment "Mac TestFlight" 2>&1)"
expect_ok "--environment sets up that channel" grep -qF "environments/Mac%20TestFlight" <<< "$one_plan"
expect_fail "and no other" grep -qF "environments/iOS%20TestFlight" <<< "$one_plan"
expect_fail "rejects a channel that doesn't exist" "$ci/setup-github.sh" --asc-key "$key" --asc-issuer-id "$issuer" --environment release
expect_fail "rejects a Developer ID identity without 'Mac download'" "$ci/setup-github.sh" --asc-key "$key" --asc-issuer-id "$issuer" \
    --environment "iOS TestFlight" --developer-id-p12 "$key"
expect_fail "rejects a bad issuer" "$ci/setup-github.sh" --asc-key "$key" --asc-issuer-id nope
expect_fail "rejects a missing key" "$ci/setup-github.sh" --asc-key "$work/none.p8" --asc-issuer-id "$issuer"

# --- approve-release.sh against a fake gh -----------------------------------------------------------
echo "approve-release.sh"
mkdir -p "$work/approve-bin" "$work/approve-gh"
cp "$here/fake_gh.sh" "$work/approve-bin/gh"
chmod +x "$work/approve-bin/gh"
# approve_release [ARGS...]: run 4242 waits on the three channels unless pending.json says otherwise.
approve_release() {
    : > "$work/approve-gh/calls"
    rm -f "$work/approve-gh/reviews"
    PATH="$work/approve-bin:$PATH" GH_STATE="$work/approve-gh" "$ci/../approve-release.sh" "$@" > "$work/approve.out" 2>&1
}
channels_pending() {
    jq -n --argjson can "${1:-true}" '[{id: 11, name: "iOS TestFlight"}, {id: 12, name: "Mac TestFlight"}, {id: 13, name: "Mac download"}]
        | map({environment: ., current_user_can_approve: $can})' > "$work/approve-gh/pending.json"
}
echo 4242 > "$work/approve-gh/waiting-run"
channels_pending
expect_ok "approves the waiting run" approve_release
expect_eq "every channel, in one review" '{"environment_ids":[11,12,13],"state":"approved","comment":""}' "$(cat "$work/approve-gh/reviews")"
expect_ok "and says which" grep -qF 'approved: iOS TestFlight, Mac TestFlight, Mac download' "$work/approve.out"
expect_ok "--skip rejects that channel" approve_release --skip ios-testflight --comment "Mac only"
expect_eq "the rest approved, it rejected" \
    '{"environment_ids":[12,13],"state":"approved","comment":"Mac only"}|{"environment_ids":[11],"state":"rejected","comment":"Mac only"}' \
    "$(paste -sd '|' - < "$work/approve-gh/reviews")"
expect_ok "a skip by the environment's own name" approve_release --skip "Mac download" --skip mac-testflight
expect_eq "(both rejected, in the run's order)" '[12,13]' "$(jq -c 'select(.state == "rejected") | .environment_ids' "$work/approve-gh/reviews")"
expect_ok "--dry-run" approve_release --dry-run
expect_ok "changes nothing" test ! -e "$work/approve-gh/reviews"
expect_ok "--run names the run" approve_release --run 77
expect_ok "(that one)" grep -qF 'actions/runs/77/pending_deployments' "$work/approve-gh/calls"
: > "$work/approve-gh/waiting-run"
expect_fail "no waiting run fails" approve_release
expect_ok "and says so" grep -qF 'no Release run is waiting' "$work/approve.out"
echo 4242 > "$work/approve-gh/waiting-run"
channels_pending false
expect_fail "a channel you can't approve fails" approve_release
expect_ok "before reviewing anything" test ! -e "$work/approve-gh/reviews"
echo '[]' > "$work/approve-gh/pending.json"
expect_fail "a run waiting on nothing fails" approve_release
expect_fail "a bad --run fails" approve_release --run abc

# --- await-validation.sh against a fake gh, whose answers change from one call to the next ----------
echo "await-validation.sh"
await_validation() {
    : > "$work/approve-gh/calls"
    PATH="$work/approve-bin:$PATH" GH_STATE="$work/approve-gh" "$ci/await-validation.sh" --repo example/daybook \
        --interval 0 "$@" > "$work/await.out" 2>&1
}
# run_state ID STATUS[:CONCLUSION]...: the CI run's answers, one per call.
run_state() {
    local id="$1" state
    shift
    for state in "$@"; do
        if [[ "$state" == error ]]; then echo error; continue; fi
        jq -cn --arg s "${state%%:*}" --arg c "${state#*:}" '{status: $s, conclusion: (if $c == $s then null else $c end)}'
    done > "$work/approve-gh/run-$id.seq"
}
# jobs_state ID 'STATUS:CONCLUSION:NAME|…'...: the run's jobs, one listing per call.
jobs_state() {
    local id="$1" listing
    shift
    for listing in "$@"; do
        if [[ "$listing" == error ]]; then echo error; continue; fi
        jq -cn --arg l "$listing" '{jobs: [$l | split("|")[] | select(length > 0) | split(":")
            | {status: .[0], conclusion: (if .[1] == "" then null else .[1] end), name: .[2]}]}'
    done > "$work/approve-gh/jobs-$id.seq"
}
run_state 5 queued in_progress completed:success
expect_ok "waits for CI on main to pass" await_validation --ci-run 5
expect_eq "(asking until it had)" "3" "$(grep -c 'actions/runs/5' "$work/approve-gh/calls")"
expect_ok "and says so" grep -qF 'CI passed on this commit: https://github.com/example/daybook/actions/runs/5' "$work/await.out"
run_state 6 in_progress completed:failure
expect_fail "CI on main that failed fails" await_validation --ci-run 6
expect_ok "naming the run" grep -qF "CI on main didn't pass on this commit (failure): https://github.com/example/daybook/actions/runs/6" "$work/await.out"
run_state 8 error in_progress error completed:success
expect_ok "a call that can't reach GitHub is tried again, not the end of the wait" await_validation --ci-run 8
expect_eq "(every answer asked for)" "4" "$(grep -c 'actions/runs/8' "$work/approve-gh/calls")"
expect_ok "saying so" grep -qF "Couldn't read CI's run (https://github.com/example/daybook/actions/runs/8): error connecting to api.github.com; trying again in 0 s" "$work/await.out"
run_state 7 in_progress
expect_fail "gives up when the time runs out" await_validation --ci-run 7 --timeout 0
expect_ok "saying what it waited for" grep -qF 'gave up after 0 minutes: CI on main is in_progress' "$work/await.out"
validate="Validate the release commit"
jobs_state 9 "" "in_progress::$validate / Lint|queued::$validate / iPhone app|in_progress::Mac to TestFlight" \
    "completed:success:$validate / Lint|completed:success:$validate / iPhone app|completed:skipped:$validate / Prune superseded caches|in_progress::Mac to TestFlight"
expect_ok "waits for this run's validation" await_validation --run 9
expect_ok "(its jobs alone, not the signing jobs)" grep -qF 'Validation passed: 3 jobs' "$work/await.out"
expect_ok "having waited for it to start" grep -qF "Waiting: validation hasn't started" "$work/await.out"
expect_ok "then to finish" grep -qF 'Waiting: 2 of 2 validation jobs still running' "$work/await.out"
jobs_state 11 error "completed:success:$validate / Lint"
expect_ok "a jobs listing that can't be read is asked for again" await_validation --run 11
expect_ok "and then passes" grep -qF 'Validation passed: 1 jobs' "$work/await.out"
jobs_state 10 "completed:success:$validate / Lint|completed:failure:$validate / iPhone app|in_progress::$validate / Mac app"
expect_fail "a failed validation job fails at once" await_validation --run 10
expect_ok "naming it" grep -qF "validation didn't pass: $validate / iPhone app (failure)" "$work/await.out"
expect_fail "--ci-run and --run together" await_validation --ci-run 5 --run 9
expect_fail "or neither" await_validation
expect_fail "a run ID that isn't one" await_validation --run abc

# --- stable-mtimes.sh, on a scratch repository and a clone of it ----------------------------------------
echo "stable-mtimes.sh"
mtimes_repo="$work/mtimes"
mkdir -p "$mtimes_repo/Sources"
git -C "$mtimes_repo" init -q
printf 'one\n' > "$mtimes_repo/Sources/A.swift"
printf 'two\n' > "$mtimes_repo/Sources/B.swift"
printf 'one\n' > "$mtimes_repo/Sources/Same.swift"
ln -s A.swift "$mtimes_repo/Sources/Link.swift"
git -C "$mtimes_repo" add -A
git -C "$mtimes_repo" -c user.name=t -c user.email=t@example.com commit -qm one
# BSD stat on macOS; GNU stat on Linux, where -f means the file system, not a format.
mtime() { if macos; then stat -f %m "$1"; else stat -c %Y "$1"; fi; }
expect_ok "dates a checkout's files" "$ci/stable-mtimes.sh" "$mtimes_repo"
a_time="$(mtime "$mtimes_repo/Sources/A.swift")"
expect_eq "from the content: 2000-01-01 plus the blob hash's first 28 bits" \
    "$(( 946684800 + 16#$(git -C "$mtimes_repo" rev-parse HEAD:Sources/A.swift | cut -c1-7) ))" "$a_time"
expect_eq "the same content, the same time" "$a_time" "$(mtime "$mtimes_repo/Sources/Same.swift")"
expect_ok "other content, another time" test "$a_time" != "$(mtime "$mtimes_repo/Sources/B.swift")"
git clone -q "$mtimes_repo" "$work/mtimes-clone"
"$ci/stable-mtimes.sh" "$work/mtimes-clone" > /dev/null
expect_eq "and the same in a fresh checkout" "$a_time" "$(mtime "$work/mtimes-clone/Sources/A.swift")"
printf 'eno\n' > "$work/mtimes-clone/Sources/A.swift"
touch -t 202001010000 "$work/mtimes-clone/Sources/A.swift" "$work/mtimes-reference"
"$ci/stable-mtimes.sh" "$work/mtimes-clone" > /dev/null
expect_eq "a file edited since (the same size) keeps its own time" "$(mtime "$work/mtimes-reference")" \
    "$(mtime "$work/mtimes-clone/Sources/A.swift")"
git -C "$work/mtimes-clone" add Sources/A.swift
"$ci/stable-mtimes.sh" "$work/mtimes-clone" > /dev/null
expect_ok "and once added, gets its new content's" test "$a_time" != "$(mtime "$work/mtimes-clone/Sources/A.swift")"
expect_fail "outside a checkout it fails" "$ci/stable-mtimes.sh" "$work/approve-bin"

# --- changes.sh, on a scratch repository: what a pull request changed ---------------------------------
echo "changes.sh"
changes_repo="$work/changes"
mkdir -p "$changes_repo/docs" "$changes_repo/Sources/App"
git -C "$changes_repo" init -q
commit_changes() { git -C "$changes_repo" add -A && git -C "$changes_repo" -c user.name=t -c user.email=t@example.com commit -qm "$1"; }
printf 'one\n' > "$changes_repo/docs/guide.md"
printf 'let a = 1\n' > "$changes_repo/Sources/App/A.swift"
commit_changes base
changes() { (cd "$changes_repo" && "$ci/changes.sh" "$@" 2>/dev/null); }
printf 'two\n' >> "$changes_repo/docs/guide.md"
printf '# Notes\n' > "$changes_repo/CHANGELOG.md"
commit_changes docs
expect_eq "a pull request that changes only documentation skips the builds" "code=false" "$(changes --event pull_request)"
expect_eq "a push never does" "code=true" "$(changes --event push)"
expect_eq "nor a release's validation" "code=true" "$(changes --event workflow_call)"
printf 'Licenses\n' > "$changes_repo/THIRD_PARTY_NOTICES.md"
commit_changes notices
expect_eq "the notices the apps bundle are code" "code=true" "$(changes --event pull_request)"
printf 'Read me\n' > "$changes_repo/Sources/App/README.md"
commit_changes source-markdown
expect_eq "so is Markdown among the sources" "code=true" "$(changes --event pull_request)"
printf 'let a = 2\n' > "$changes_repo/Sources/App/A.swift"
commit_changes code
expect_eq "and code is" "code=true" "$(changes --event pull_request)"
expect_eq "a base it can't compare with checks everything" "code=true" "$(changes --event pull_request --base no-such-ref)"
expect_fail "--event is required" "$ci/changes.sh"

# --- build-ios.sh upload retry, with a stand-in xcodebuild --------------------------------------------
echo "build-ios.sh upload retry"
if macos; then
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
else
    skip "build-ios.sh upload retry (macOS only)"
fi

# --- build-app.sh, with stand-in Xcode tools, in a copy of the repository ------------------------------
echo "build-app.sh"
if macos; then
    mac_repo="$work/mac-repo"
    mkdir -p "$mac_repo/scripts/lib" "$mac_repo/Apps/macOS/Config"
    cp "$ci/../build-app.sh" "$mac_repo/scripts/"
    cp "$ci/../lib/build-common.sh" "$mac_repo/scripts/lib/"
    cp "$ci/../../Package.resolved" "$mac_repo/"
    : > "$mac_repo/Apps/macOS/project.yml"
    # build_app [VAR=value...] -- ARGS: build-app.sh with only the given DAYBOOK_* and GitHub workflow variables (a run inside
    # release.yml must not look like the release pipeline to the tests that say otherwise).
    build_app() {
        local vars=()
        while [[ "$1" != -- ]]; do vars+=("$1"); shift; done
        shift
        : > "$work/stub.log"
        env -u DAYBOOK_TEAM_ID -u DAYBOOK_ASC_KEY_PATH -u DAYBOOK_ASC_KEY_ID -u DAYBOOK_ASC_ISSUER_ID \
            -u DAYBOOK_DEVELOPER_ID_PROFILE -u DAYBOOK_NOTARY_PROFILE -u DAYBOOK_MAC_DERIVED_DATA \
            -u DAYBOOK_REHEARSAL_BUNDLE_ID -u DAYBOOK_SANDBOX -u GITHUB_ACTIONS -u GITHUB_WORKFLOW_REF \
            PATH="$stubs:$PATH" STUB_LOG="$work/stub.log" XCODEGEN="$stubs/xcodegen" ${vars[@]+"${vars[@]}"} \
            "$mac_repo/scripts/build-app.sh" "$@" > "$work/build-app.out" 2>&1
    }
    xcb() { grep "^xcodebuild .*$1" "$work/stub.log" || true; }
    pipeline=(GITHUB_ACTIONS=true GITHUB_WORKFLOW_REF=example/daybook/.github/workflows/release.yml@refs/tags/v1.4.0)
    asc_vars=("${pipeline[@]}" DAYBOOK_ASC_KEY_PATH="$key" DAYBOOK_ASC_KEY_ID=ABC123DEFG DAYBOOK_ASC_ISSUER_ID="$issuer")
    no_pipeline=(DAYBOOK_ASC_KEY_PATH="$key" DAYBOOK_ASC_KEY_ID=ABC123DEFG DAYBOOK_ASC_ISSUER_ID="$issuer")
    export_options="$mac_repo/build/macOS/ExportOptions.plist"

    expect_ok "an ad hoc debug build" build_app -- --debug --ad-hoc
    expect_ok "builds Debug, signed locally" grep -q -- '-configuration Debug .* build .*DAYBOOK_SIGNING=local' <<< "$(xcb ' build ')"
    expect_ok "packages dist/Daybook.app and the ZIP" test -d "$mac_repo/dist/Daybook.app" -a -f "$mac_repo/dist/Daybook-macOS-arm64.zip"
    expect_eq "a local build never asks to change the account" "" "$(grep -- '-allowProvisioning' "$work/stub.log" || true)"
    expect_ok "a migration rehearsal" build_app -- --sandbox-rehearsal --debug
    expect_ok "is ad hoc, under the rehearsal's own bundle ID" \
        grep -q -- 'DAYBOOK_SIGNING=rehearsal .*DAYBOOK_BUNDLE_ID_rehearsal=local.daybook.rehearsal' <<< "$(xcb ' build ')"
    expect_ok "another rehearsal from scratch" build_app DAYBOOK_REHEARSAL_BUNDLE_ID=local.daybook.rehearsal2 -- --sandbox-rehearsal --debug
    expect_ok "takes a new bundle ID" grep -q -- 'DAYBOOK_BUNDLE_ID_rehearsal=local.daybook.rehearsal2' <<< "$(xcb ' build ')"
    expect_fail "a rehearsal never takes the app's bundle ID" build_app DAYBOOK_REHEARSAL_BUNDLE_ID=local.daybook -- --sandbox-rehearsal
    expect_fail "nor the earlier one's" build_app DAYBOOK_REHEARSAL_BUNDLE_ID=local.daybook.app.rehearsal -- --sandbox-rehearsal
    expect_fail "and never changes the account" build_app DAYBOOK_TEAM_ID=48H7CLBV8Y -- --sandbox-rehearsal --allow-provisioning-updates
    expect_ok "an ad hoc release archive" build_app -- --ad-hoc
    expect_eq "is archived, not exported" "1 0" "$(xcb ' archive ' | wc -l | tr -d ' ') $(xcb '-exportArchive' | wc -l | tr -d ' ')"
    expect_ok "signed builds aren't sandboxed by default" build_app DAYBOOK_TEAM_ID=48H7CLBV8Y -- --archive-only
    expect_ok "(DAYBOOK_SANDBOX=NO)" grep -q -- 'DAYBOOK_SIGNING=signed .*DAYBOOK_SANDBOX=NO' <<< "$(xcb ' archive ')"
    expect_ok "--sandbox: a sandboxed signed release" build_app DAYBOOK_TEAM_ID=48H7CLBV8Y -- --sandbox --archive-only
    expect_ok "(DAYBOOK_SANDBOX=YES)" grep -q -- 'DAYBOOK_SIGNING=signed .*DAYBOOK_SANDBOX=YES' <<< "$(xcb ' archive ')"
    expect_ok "and says the first launch moves the library" grep -q "moves ~/Library/Application Support/Daybook" "$work/build-app.out"
    expect_ok "DAYBOOK_SANDBOX=1 is the same" build_app DAYBOOK_TEAM_ID=48H7CLBV8Y DAYBOOK_SANDBOX=1 -- --archive-only
    expect_ok "(DAYBOOK_SANDBOX=YES again)" grep -q -- 'DAYBOOK_SANDBOX=YES' <<< "$(xcb ' archive ')"
    rm -rf "$mac_repo/dist"
    expect_ok "--app-store: the Mac App Store and TestFlight build" build_app DAYBOOK_TEAM_ID=48H7CLBV8Y -- --app-store \
        --marketing-version 1.4.0 --build-number 1057
    expect_ok "is the sandboxed signed build" grep -q -- 'DAYBOOK_SIGNING=signed .*DAYBOOK_SANDBOX=YES .*CURRENT_PROJECT_VERSION=1057' <<< "$(xcb ' archive ')"
    expect_eq "exported for App Store Connect, to build/macOS/AppStore" "app-store-connect export automatic false" \
        "$(plutil -extract method raw "$export_options") $(plutil -extract destination raw "$export_options") $(plutil -extract signingStyle raw "$export_options") $(plutil -extract manageAppVersionAndBuildNumber raw "$export_options")"
    expect_ok "(the export path)" grep -q -- "-exportPath $mac_repo/build/macOS/AppStore " <<< "$(xcb '-exportArchive')"
    expect_eq "with no iCloud environment of its own: the App Store sets Production" "" \
        "$(plutil -extract iCloudContainerEnvironment raw "$export_options" 2>/dev/null || true)"
    expect_ok "and nothing in dist/" test ! -e "$mac_repo/dist/Daybook.app"
    expect_ok "--app-store --upload sends it to App Store Connect" build_app DAYBOOK_TEAM_ID=48H7CLBV8Y "${asc_vars[@]}" -- \
        --app-store --upload --export-only
    expect_eq "(destination upload, with the key)" "upload 1" \
        "$(plutil -extract destination raw "$export_options") $(xcb '-exportArchive' | grep -c -- '-allowProvisioningUpdates -authenticationKeyPath')"
    expect_fail "--upload is for --app-store" build_app DAYBOOK_TEAM_ID=48H7CLBV8Y -- --upload
    expect_fail "--app-store needs a team" build_app -- --app-store
    expect_fail "and a Release build" build_app DAYBOOK_TEAM_ID=48H7CLBV8Y -- --app-store --debug
    expect_fail "a sandboxed Debug build could create the app's container" build_app DAYBOOK_TEAM_ID=48H7CLBV8Y -- --sandbox --debug
    expect_fail "--sandbox needs a team" build_app -- --sandbox
    expect_fail "and isn't for ad hoc builds" build_app DAYBOOK_TEAM_ID=48H7CLBV8Y -- --sandbox --ad-hoc
    expect_fail "DAYBOOK_SANDBOX takes 1 or 0" build_app DAYBOOK_TEAM_ID=48H7CLBV8Y DAYBOOK_SANDBOX=maybe --
    expect_ok "the release pipeline's signed build" build_app DAYBOOK_TEAM_ID=48H7CLBV8Y "${asc_vars[@]}" -- \
        --marketing-version 1.4.0 --build-number 1057
    expect_ok "archives with the key and versions" grep -q -- "-allowProvisioningUpdates -authenticationKeyPath $key .* archive .*MARKETING_VERSION=1.4.0 CURRENT_PROJECT_VERSION=1057" <<< "$(xcb ' archive ')"
    expect_eq "never registers devices" "" "$(grep -- '-allowProvisioningDeviceRegistration' "$work/stub.log" || true)"
    expect_ok "exports with cloud-managed signing" grep -q -- '-exportArchive .*-allowProvisioningUpdates -authenticationKeyPath' <<< "$(xcb '-exportArchive')"
    expect_eq "export options" "developer-id automatic Production" \
        "$(plutil -extract method raw "$export_options") $(plutil -extract signingStyle raw "$export_options") $(plutil -extract iCloudContainerEnvironment raw "$export_options")"
    expect_ok "with the Developer ID profile" build_app DAYBOOK_TEAM_ID=48H7CLBV8Y "${asc_vars[@]}" \
        DAYBOOK_DEVELOPER_ID_PROFILE=01234567-89ab-cdef-0123-456789abcdef --
    expect_eq "the export signs manually, without the key" "" "$(xcb '-exportArchive' | grep -- '-authenticationKey' || true)"
    expect_eq "manual export options" "manual 01234567-89ab-cdef-0123-456789abcdef" \
        "$(plutil -extract signingStyle raw "$export_options") $(plutil -extract 'provisioningProfiles.local\.daybook' raw "$export_options")"
    expect_ok "the profile follows the archived app's bundle ID" build_app DAYBOOK_TEAM_ID=48H7CLBV8Y "${asc_vars[@]}" \
        STUB_BUNDLE_ID=local.daybook.app DAYBOOK_DEVELOPER_ID_PROFILE=01234567-89ab-cdef-0123-456789abcdef --
    expect_eq "(an archive from before the one bundle ID)" "01234567-89ab-cdef-0123-456789abcdef" \
        "$(plutil -extract 'provisioningProfiles.local\.daybook\.app' raw "$export_options")"
    expect_ok "packages are fetched at the pinned versions" build_app -- --resolve-only
    expect_eq "and nothing is built" "xcodebuild -resolvePackageDependencies" "$(grep '^xcodebuild' "$work/stub.log" | cut -d' ' -f1-2)"
    expect_ok "resolution is held to Package.resolved" grep -q -- '-onlyUsePackageVersionsFromResolvedFile' <<< "$(xcb resolvePackageDependencies)"
    expect_fail "a resolution that changes Package.resolved fails" build_app STUB_RESOLVE_CHANGES=1 -- --ad-hoc
    expect_ok "and says so" grep -q "other package versions" "$work/build-app.out"
    expect_eq "before building anything" "" "$(xcb ' archive ')"
    build_app -- --ad-hoc || true
    expect_ok "the archive is held to the pinned versions too" grep -q -- '-onlyUsePackageVersionsFromResolvedFile' <<< "$(xcb ' archive ')"
    expect_ok "--archive-only: the archive step alone" build_app DAYBOOK_TEAM_ID=48H7CLBV8Y "${asc_vars[@]}" -- \
        --archive-only --marketing-version 1.4.0 --build-number 1057
    expect_eq "archives with the key, exports nothing" "1 0" \
        "$(xcb ' archive ' | grep -c -- '-authenticationKeyPath') $(xcb '-exportArchive' | wc -l | tr -d ' ')"
    expect_ok "--export-only: the export step alone, from that archive" build_app DAYBOOK_TEAM_ID=48H7CLBV8Y "${asc_vars[@]}" \
        DAYBOOK_DEVELOPER_ID_PROFILE=01234567-89ab-cdef-0123-456789abcdef -- --export-only
    expect_eq "neither generates, resolves, nor archives" "xcodebuild -exportArchive" \
        "$(grep -E '^(xcodebuild|xcodegen)' "$work/stub.log" | cut -d' ' -f1-2 | paste -sd '|' -)"
    expect_ok "and packages the export" test -d "$mac_repo/dist/Daybook.app"
    rm -rf "$mac_repo/build/macOS/Daybook.xcarchive"
    expect_fail "--export-only without an archive fails" build_app DAYBOOK_TEAM_ID=48H7CLBV8Y -- --export-only
    expect_fail "--archive-only is for Release" build_app -- --archive-only --debug
    expect_fail "one mode at a time" build_app -- --archive-only --export-only
    expect_fail "the API key is refused outside the release pipeline" build_app DAYBOOK_TEAM_ID=48H7CLBV8Y "${no_pipeline[@]}" --
    expect_eq "before anything runs" "" "$(grep '^xcodebuild' "$work/stub.log" || true)"
    expect_fail "and in another workflow" build_app DAYBOOK_TEAM_ID=48H7CLBV8Y "${no_pipeline[@]}" GITHUB_ACTIONS=true \
        GITHUB_WORKFLOW_REF=example/daybook/.github/workflows/ci.yml@refs/heads/main --
    expect_fail "provisioning updates need a team" build_app -- --allow-provisioning-updates --ad-hoc
    expect_fail "part of the API key is refused" build_app DAYBOOK_TEAM_ID=48H7CLBV8Y DAYBOOK_ASC_KEY_ID=ABC123DEFG --
else
    skip "build-app.sh (macOS only)"
fi

# --- check-mac-app.sh, on stand-in apps signed ad hoc with the repository's entitlements ----------------
echo "check-mac-app.sh"
if macos; then
    resources="$ci/../../Resources"
    # fake_app NAME BUNDLE_ID ENTITLEMENTS [MANIFEST]: an app whose executable is a copy of true, signed ad hoc.
    fake_app() {
        local app="$work/apps/$1/Daybook.app"
        umask 022
        /bin/rm -rf "$work/apps/$1"
        /bin/mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
        /bin/cp /usr/bin/true "$app/Contents/MacOS/Daybook"
        plutil -create xml1 "$app/Contents/Info.plist"
        plutil -insert CFBundleIdentifier -string "$2" "$app/Contents/Info.plist"
        plutil -insert CFBundleExecutable -string Daybook "$app/Contents/Info.plist"
        if [[ -n "${4-}" ]]; then /bin/cp "$4" "$app/Contents/Resources/container-migration.plist"; fi
        codesign -s - -f --entitlements "$3" "$app" 2>/dev/null
        printf '%s' "$app"
    }
    check_app() { "$ci/check-mac-app.sh" "$@" > "$work/check-app.out" 2>&1; }
    local_ent="$resources/Daybook-Local.entitlements"
    app="$(fake_app adhoc local.daybook.adhoc "$local_ent")"
    expect_ok "the ad hoc entitlements make a sandboxed ad hoc build" check_app --app "$app" --kind adhoc
    expect_fail "which isn't a signed build" check_app --app "$app" --kind signed
    expect_fail "an ad hoc build under the app's bundle ID" check_app --app "$(fake_app adhoc-id local.daybook "$local_ent")" --kind adhoc
    expect_ok "is refused for its bundle ID" grep -q "bundle ID is 'local.daybook'" "$work/check-app.out"
    expect_fail "an ad hoc build with a manifest" \
        check_app --app "$(fake_app adhoc-manifest local.daybook.adhoc "$local_ent" "$resources/container-migration.plist")" --kind adhoc
    expect_ok "is refused: it could move a library" grep -q "mustn't carry container-migration.plist" "$work/check-app.out"
    plutil -remove 'com\.apple\.security\.device\.bluetooth' -o "$work/no-bluetooth.entitlements" "$local_ent"
    expect_fail "a sandboxed build without Bluetooth" \
        check_app --app "$(fake_app no-bluetooth local.daybook.adhoc "$work/no-bluetooth.entitlements")" --kind adhoc
    plutil -replace 'com\.apple\.security\.temporary-exception\.files\.absolute-path\.read-write' -json '["/"]' \
        -o "$work/wide.entitlements" "$local_ent"
    expect_fail "an exception wider than /private/tmp/daybook/" \
        check_app --app "$(fake_app wide local.daybook.adhoc "$work/wide.entitlements")" --kind adhoc
    app="$(fake_app rehearsal local.daybook.rehearsal2 "$local_ent" "$resources/container-migration-rehearsal.plist")"
    expect_ok "a rehearsal build moves only the rehearsal's library" check_app --app "$app" --kind rehearsal
    expect_fail "a rehearsal with the real manifest" \
        check_app --app "$(fake_app rehearsal-real local.daybook.rehearsal "$local_ent" "$resources/container-migration.plist")" --kind rehearsal
    app="$(fake_app signed local.daybook "$resources/Daybook.entitlements")"
    expect_ok "the signed entitlements make an unsandboxed signed build" check_app --app "$app" --kind signed
    expect_fail "which isn't a sandboxed one" check_app --app "$app" --kind signed-sandbox
    expect_fail "a signed build with a manifest" \
        check_app --app "$(fake_app signed-manifest local.daybook "$resources/Daybook.entitlements" "$resources/container-migration.plist")" --kind signed
    sandbox_ent="$resources/Daybook-Sandbox.entitlements"
    app="$(fake_app signed-sandbox local.daybook "$sandbox_ent" "$resources/container-migration.plist")"
    expect_ok "the sandboxed signed entitlements and the manifest make a sandboxed release" check_app --app "$app" --kind signed-sandbox
    expect_fail "which isn't the default signed build" check_app --app "$app" --kind signed
    expect_fail "a sandboxed release under the earlier bundle ID" \
        check_app --app "$(fake_app signed-sandbox-app-id local.daybook.app "$sandbox_ent" "$resources/container-migration.plist")" --kind signed-sandbox
    expect_ok "is refused for its bundle ID" grep -q "bundle ID is 'local.daybook.app', expected local.daybook" "$work/check-app.out"
    expect_fail "a sandboxed release without the manifest" \
        check_app --app "$(fake_app signed-sandbox-bare local.daybook "$sandbox_ent")" --kind signed-sandbox
    expect_fail "a sandboxed release with the rehearsal's manifest" \
        check_app --app "$(fake_app signed-sandbox-rehearsal local.daybook "$sandbox_ent" "$resources/container-migration-rehearsal.plist")" --kind signed-sandbox
    expect_fail "a sandboxed release with a temporary exception" \
        check_app --app "$(fake_app signed-sandbox-exception local.daybook "$local_ent" "$resources/container-migration.plist")" --kind signed-sandbox
    # shellcheck disable=SC2016 # the manifest's own variables, never expanded here
    plutil -replace Move -json '["${ApplicationSupport}/Daybook","${Library}/Preferences/${BundleId}.plist"]' \
        -o "$work/same-name-manifest.plist" "$resources/container-migration.plist"
    expect_fail "a manifest that leaves the earlier release's preferences behind" \
        check_app --app "$(fake_app signed-sandbox-same-name local.daybook "$sandbox_ent" "$work/same-name-manifest.plist")" --kind signed-sandbox
    # Built under umask 077: installed from a package, as root's, nobody else could read it.
    app="$(fake_app private-file local.daybook "$sandbox_ent" "$resources/container-migration.plist")"
    chmod 700 "$app/Contents/MacOS/Daybook"
    expect_fail "a release with a file only its owner can read" check_app --app "$app" --kind signed-sandbox
    expect_ok "names it" grep -q "only its owner can read Contents/MacOS/Daybook: an installer package" "$work/check-app.out"
    app="$(fake_app private-folder local.daybook "$resources/Daybook.entitlements")"
    chmod 700 "$app/Contents/Resources"
    expect_fail "or a folder" check_app --app "$app" --kind signed
    # Daybook-Sandbox.entitlements is Daybook.entitlements plus the App Sandbox's keys, nothing else: a key added to one
    # (keychain access groups, say) has to be added to the other.
    entitlement_keys() { plutil -p "$1" | sed -n 's/^  "\([^"]*\)" =>.*/\1/p' | sort; }
    sandbox_only="com.apple.security.app-sandbox com.apple.security.device.bluetooth com.apple.security.device.microphone com.apple.security.files.bookmarks.app-scope com.apple.security.files.user-selected.read-write com.apple.security.network.client com.apple.security.network.server"
    expect_eq "the sandboxed signed entitlements add only the sandbox's keys" "$sandbox_only" \
        "$(comm -13 <(entitlement_keys "$resources/Daybook.entitlements") <(entitlement_keys "$sandbox_ent") | paste -sd ' ' -)"
    expect_eq "and keep every signed key" "" "$(comm -23 <(entitlement_keys "$resources/Daybook.entitlements") <(entitlement_keys "$sandbox_ent") | paste -sd ' ' -)"
    differing=""
    for entitlement in $(entitlement_keys "$resources/Daybook.entitlements"); do
        escaped="${entitlement//./\\.}"
        if [[ "$(plutil -extract "$escaped" xml1 -o - "$resources/Daybook.entitlements")" != "$(plutil -extract "$escaped" xml1 -o - "$sandbox_ent")" ]]; then
            differing="$differing $entitlement"
        fi
    done
    expect_eq "with the same values" "" "${differing# }"
else
    skip "check-mac-app.sh (macOS only)"
fi

# --- build-ios.sh, with stand-in Xcode tools, in a copy of the repository ------------------------------
echo "build-ios.sh"
if macos; then
    ios_repo="$work/ios-repo"
    mkdir -p "$ios_repo/scripts/lib" "$ios_repo/scripts/ci" "$ios_repo/Apps/iOS/Config"
    cp "$ci/../build-ios.sh" "$ios_repo/scripts/"
    cp "$ci/../lib/build-common.sh" "$ios_repo/scripts/lib/"
    cp "$ci/pick-simulator.sh" "$ios_repo/scripts/ci/"
    cp "$ci/../../Package.resolved" "$ios_repo/"
    : > "$ios_repo/Apps/iOS/project.yml"
    build_ios() {
        local vars=()
        while [[ "$1" != -- ]]; do vars+=("$1"); shift; done
        shift
        : > "$work/stub.log"
        env -u DAYBOOK_TEAM_ID -u DAYBOOK_ASC_KEY_PATH -u DAYBOOK_ASC_KEY_ID -u DAYBOOK_ASC_ISSUER_ID -u DAYBOOK_IOS_DERIVED_DATA \
            -u GITHUB_ACTIONS -u GITHUB_WORKFLOW_REF \
            PATH="$stubs:$PATH" STUB_LOG="$work/stub.log" XCODEGEN="$stubs/xcodegen" ${vars[@]+"${vars[@]}"} \
            "$ios_repo/scripts/build-ios.sh" "$@" > "$work/build-ios.out" 2>&1
    }
    expect_ok "packages are fetched at the pinned versions" build_ios -- --resolve
    expect_eq "and nothing is built" "xcodebuild -resolvePackageDependencies" "$(grep '^xcodebuild' "$work/stub.log" | cut -d' ' -f1-2)"
    expect_ok "resolution is held to Package.resolved" grep -q -- '-onlyUsePackageVersionsFromResolvedFile' <<< "$(xcb resolvePackageDependencies)"
    expect_fail "a resolution that changes Package.resolved fails" build_ios STUB_RESOLVE_CHANGES=1 -- --archive --no-sign
    expect_eq "before building anything" "" "$(xcb ' archive')"
    expect_ok "an unsigned archive" build_ios -- --archive --no-sign --marketing-version 1.4.0 --build-number 1057
    expect_ok "is held to the pinned versions" grep -q -- '-onlyUsePackageVersionsFromResolvedFile .*archive CODE_SIGNING_ALLOWED=NO' <<< "$(xcb ' archive')"
    expect_ok "the release pipeline's signed archive" build_ios DAYBOOK_TEAM_ID=48H7CLBV8Y "${asc_vars[@]}" -- --archive
    expect_ok "authenticates with the key" grep -q -- "-allowProvisioningUpdates -authenticationKeyPath $key .* archive DAYBOOK_TEAM_ID=48H7CLBV8Y" <<< "$(xcb ' archive')"
    expect_eq "never registers devices" "" "$(grep -- '-allowProvisioningDeviceRegistration' "$work/stub.log" || true)"
    expect_fail "the API key is refused outside the release pipeline" build_ios DAYBOOK_TEAM_ID=48H7CLBV8Y "${no_pipeline[@]}" -- --archive
    expect_eq "before anything runs" "" "$(grep '^xcodebuild' "$work/stub.log" || true)"
    expect_fail "and in another workflow" build_ios DAYBOOK_TEAM_ID=48H7CLBV8Y "${no_pipeline[@]}" GITHUB_ACTIONS=true \
        GITHUB_WORKFLOW_REF=example/daybook/.github/workflows/ci.yml@refs/heads/main -- --archive
    expect_fail "part of the API key is refused" build_ios DAYBOOK_TEAM_ID=48H7CLBV8Y DAYBOOK_ASC_KEY_ID=ABC123DEFG -- --archive
    expect_ok "a device build never passes -allowProvisioningUpdates" build_ios DAYBOOK_TEAM_ID=48H7CLBV8Y -- --device
    expect_eq "(none in the calls)" "" "$(grep -- '-allowProvisioning' "$work/stub.log" || true)"
    expect_ok "an upload's export options" build_ios DAYBOOK_TEAM_ID=48H7CLBV8Y "${asc_vars[@]}" -- --archive --export upload
    ios_options="$ios_repo/Apps/iOS/build/ExportOptions.plist"
    expect_eq "(app-store-connect, upload, automatic, the team, and the pipeline's build number)" \
        "app-store-connect upload automatic 48H7CLBV8Y false" \
        "$(plutil -extract method raw "$ios_options") $(plutil -extract destination raw "$ios_options") $(plutil -extract signingStyle raw "$ios_options") $(plutil -extract teamID raw "$ios_options") $(plutil -extract manageAppVersionAndBuildNumber raw "$ios_options")"

    # --test picks its simulator first (scripts/ci/pick-simulator.sh), from a stand-in simctl.
    printf '%s\n' '{"devices": {' \
        '"com.apple.CoreSimulator.SimRuntime.iOS-27-0": [' \
        '  {"name": "iPhone 17", "udid": "AAAAAAAA-0000-0000-0000-000000000017", "isAvailable": true},' \
        '  {"name": "iPhone 18 Pro", "udid": "AAAAAAAA-0000-0000-0000-000000000018", "isAvailable": true}],' \
        '"com.apple.CoreSimulator.SimRuntime.watchOS-12-0": [' \
        '  {"name": "Apple Watch Ultra 3", "udid": "AAAAAAAA-0000-0000-0000-0000000000AA", "isAvailable": true}]}}' \
        > "$work/simulators.json"
    expect_ok "--test without an iPhone Duo tests on the iPhone 18 Pro" build_ios STUB_SIMULATORS="$work/simulators.json" -- --test
    expect_ok "(by its UDID)" grep -q -- '-destination id=AAAAAAAA-0000-0000-0000-000000000018 test-without-building$' <<< "$(xcb ' test')"
    # One build, the same every time: the generic destination for this Mac's architecture only.
    sim_build="-destination generic/platform=iOS Simulator ARCHS=$(uname -m)"
    expect_eq "after building for testing once, for this Mac's architecture" \
        "-resolvePackageDependencies|$sim_build build-for-testing|-destination id=AAAAAAAA-0000-0000-0000-000000000018 test-without-building" \
        "$(grep '^xcodebuild' "$work/stub.log" | sed -E 's/.*(-resolvePackageDependencies).*/\1/; s/.*(-destination .*)/\1/' | paste -sd '|' -)"
    expect_ok "--build-for-testing builds" build_ios -- --build-for-testing
    expect_eq "and tests nothing" "$sim_build build-for-testing" \
        "$(grep '^xcodebuild .*-destination' "$work/stub.log" | sed -E 's/.*(-destination .*)/\1/')"
    expect_ok "--test --skip-build tests what was built" build_ios -- --test --skip-build --simulator "iPhone 18 Pro" \
        --test-arg -only-testing:DaybookPhoneTests/ShellTests
    expect_eq "without generating, resolving, or building" \
        "xcodebuild -destination platform=iOS Simulator,name=iPhone 18 Pro test-without-building -only-testing:DaybookPhoneTests/ShellTests" \
        "$(grep -E '^(xcodebuild|xcodegen)' "$work/stub.log" | sed -E 's/^(xcodebuild).*(-destination .*)/\1 \2/')"
    expect_ok "a plain build is the same simulator build" build_ios -- --simulator unused
    expect_eq "(no tests)" "$sim_build build" "$(grep '^xcodebuild .*-destination' "$work/stub.log" | sed -E 's/.*(-destination .*)/\1/')"
    expect_fail "--skip-build without --test" build_ios -- --skip-build
    expect_fail "--build-for-testing with --test" build_ios -- --build-for-testing --test
    expect_fail "--build-for-testing for a device" build_ios -- --build-for-testing --device --no-sign
    echo '{"devices": {}}' > "$work/no-simulators.json"
    expect_fail "--test with no iPhone simulator fails" build_ios STUB_SIMULATORS="$work/no-simulators.json" -- --test
    expect_ok "and says so" grep -q "No iPhone simulator is available for --test" "$work/build-ios.out"
    expect_eq "before anything is built" "" "$(grep -E '^(xcodebuild|xcodegen)' "$work/stub.log" || true)"
    expect_ok "--simulator needs no choice" build_ios STUB_SIMULATORS="$work/no-simulators.json" -- --test --simulator "iPhone 18 Pro"
    expect_ok "(by name)" grep -q -- '-destination platform=iOS Simulator,name=iPhone 18 Pro test' <<< "$(xcb ' test')"
else
    skip "build-ios.sh (macOS only)"
fi

# --- package-mac.sh, with stand-in tools ----------------------------------------------------------------
echo "package-mac.sh"
if macos; then
    make_mac_app() {
        # make_mac_app DIR VERSION BUILD
        local app="$1/Daybook.app"
        rm -rf "$app"
        mkdir -p "$app/Contents/MacOS"
        plutil -create xml1 "$app/Contents/Info.plist"
        plutil -insert CFBundleIdentifier -string local.daybook "$app/Contents/Info.plist"
        plutil -insert CFBundleShortVersionString -string "$2" "$app/Contents/Info.plist"
        plutil -insert CFBundleVersion -string "$3" "$app/Contents/Info.plist"
    }
    package() {
        : > "$work/stub.log"
        env -u DAYBOOK_ASC_KEY_PATH -u DAYBOOK_ASC_KEY_ID -u DAYBOOK_ASC_ISSUER_ID -u DAYBOOK_TEAM_ID \
            PATH="$stubs:$PATH" STUB_LOG="$work/stub.log" "$ci/package-mac.sh" "$@" > "$work/package.out" 2>&1
    }
    files_in() { find "$1" -type f -exec basename {} \; | sort | paste -sd ' ' -; }
    make_mac_app "$work/pkg" 1.4.0 1057
    expect_ok "packages a local build" package --app "$work/pkg/Daybook.app" --version 1.4.0 --build 1057 --output "$work/pkg-out"
    expect_eq "a ZIP, an unsigned DMG, and checksums" "Daybook-1.4.0-macOS-arm64.dmg Daybook-1.4.0-macOS-arm64.zip SHA256SUMS.txt" \
        "$(files_in "$work/pkg-out")"
    # shellcheck disable=SC2016 # $1 is the inner shell's
    expect_ok "the checksums verify" bash -c 'cd "$1" && shasum -a 256 -c SHA256SUMS.txt' _ "$work/pkg-out"
    expect_eq "nothing goes to Apple without --notarize" "" "$(grep -E '^xcrun (notarytool|stapler)' "$work/stub.log" || true)"
    expect_fail "an app with another build number isn't packaged" package --app "$work/pkg/Daybook.app" --version 1.4.0 --build 1058 --output "$work/pkg-out2"
    expect_ok "and says which" grep -q "is build '1057' (CFBundleVersion), not 1058" "$work/package.out"
    expect_fail "nor one with another version" package --app "$work/pkg/Daybook.app" --version 1.5.0 --output "$work/pkg-out2"
    expect_ok "(nothing was written)" test ! -e "$work/pkg-out2/SHA256SUMS.txt"

    # Notarization, with a stand-in notarytool.
    notary_env=(DAYBOOK_ASC_KEY_PATH="$key" DAYBOOK_ASC_KEY_ID=ABC123DEFG DAYBOOK_ASC_ISSUER_ID="$issuer"
                DAYBOOK_TEAM_ID=48H7CLBV8Y GITHUB_STEP_SUMMARY="$work/summary.md" STUB_IDENTITY=1)
    notarize() {
        : > "$work/stub.log"
        : > "$work/summary.md"
        local vars=()
        while [[ "$1" != -- ]]; do vars+=("$1"); shift; done
        shift
        env PATH="$stubs:$PATH" STUB_LOG="$work/stub.log" "${notary_env[@]}" ${vars[@]+"${vars[@]}"} \
            "$ci/package-mac.sh" --app "$work/pkg/Daybook.app" --version 1.4.0 --build 1057 --notarize "$@" > "$work/package.out" 2>&1
    }
    calls() { grep -E "^xcrun (notarytool $1|stapler staple)" "$work/stub.log" | awk '{print $2, $3, $4}' | sed 's|[^ ]*/||g' | paste -sd '|' -; }
    app_id=11111111-2222-3333-4444-555555555555
    rm -rf "$work/notary-out" "$work/state"
    expect_ok "notarizes the app and the DMG" notarize STUB_NOTARY=accepted -- --output "$work/notary-out" --state-dir "$work/state"
    expect_eq "submits without waiting, then waits with a limit" "notarytool submit submit.zip|notarytool wait $app_id|stapler staple Daybook.app|notarytool submit Daybook-1.4.0-macOS-arm64.dmg|notarytool wait 22222222-2222-3333-4444-555555555555|stapler staple Daybook-1.4.0-macOS-arm64.dmg" \
        "$(calls '(submit|wait)')"
    expect_eq "the app's wait is 45 minutes, the DMG's 20" "45m 20m" "$(grep -o -- '--timeout [0-9a-z]*' "$work/stub.log" | awk '{print $2}' | paste -sd ' ' -)"
    expect_eq "both submissions are in the summary" "2" "$(grep -c 'submission `' "$work/summary.md")"
    expect_ok "nothing stays pending" test ! -e "$work/state/pending.json"
    expect_eq "ZIP, DMG, checksums" "Daybook-1.4.0-macOS-arm64.dmg Daybook-1.4.0-macOS-arm64.zip SHA256SUMS.txt" "$(files_in "$work/notary-out")"

    rm -rf "$work/notary-out" "$work/state"
    status=0
    notarize STUB_NOTARY=slow -- --output "$work/notary-out" --state-dir "$work/state" || status=$?
    expect_eq "a submission still in progress stops with 75" "75" "$status"
    expect_eq "and is kept for a re-run" "$app_id 1.4.0 1057" "$(jq -r '"\(.id) \(.version) \(.build)"' "$work/state/pending.json")"
    expect_ok "with exactly what was sent" test "$(shasum -a 256 "$work/state/submit.zip" | awk '{print $1}')" = "$(jq -r .sha256 "$work/state/pending.json")"
    expect_ok "and in the summary" grep -q "submission \`$app_id\`, In Progress" "$work/summary.md"
    expect_ok "nothing is packaged" test ! -e "$work/notary-out/SHA256SUMS.txt"

    # The re-run: notary-resume.sh finds attempt 1's submission.
    mkdir -p "$work/earlier/attempt-1"
    cp "$work/state/pending.json" "$work/state/submit.zip" "$work/earlier/attempt-1/"
    # resume MODE [VERSION [FROM]]
    resume() {
        : > "$work/stub.log"
        env PATH="$stubs:$PATH" STUB_LOG="$work/stub.log" "${notary_env[@]}" STUB_NOTARY="$1" \
            "$ci/notary-resume.sh" --from "${3:-$work/earlier}" --state-dir "$work/state2" --app "$work/resumed/Daybook.app" \
            --version "${2:-1.4.0}" 2>"$work/resume.err" | paste -sd ' ' -
    }
    expect_eq "a pending submission is picked up" "submission=$app_id build=1057" "$(resume slow)"
    expect_ok "the submitted app is unpacked" test -f "$work/resumed/Daybook.app/Contents/Info.plist"
    expect_ok "and its state copied" test -f "$work/state2/pending.json" -a -f "$work/state2/submit.zip"
    expect_eq "an accepted one too" "submission=$app_id build=1057" "$(resume accepted)"
    expect_eq "a rejected one isn't" "submission=" "$(resume invalid)"
    expect_eq "nor one for another version" "submission=" "$(resume slow 1.5.0)"
    printf 'x' >> "$work/earlier/attempt-1/submit.zip"
    expect_eq "nor one whose zip changed" "submission=" "$(resume slow)"
    expect_eq "nothing pending, nothing to do" "submission=" "$(resume slow 1.4.0 "$work/none")"

    # package-mac.sh --submission waits for that submission instead of sending the app again.
    rm -rf "$work/notary-out"
    expect_ok "--submission: waits for the earlier submission" notarize STUB_NOTARY=accept-later -- \
        --output "$work/notary-out" --state-dir "$work/state2" --submission "$app_id"
    expect_eq "without submitting the app again" "notarytool wait $app_id|stapler staple Daybook.app" "$(calls '(submit|wait)' | cut -d'|' -f1-2)"
    expect_fail "--submission needs its pending.json" notarize -- --output "$work/notary-out" --state-dir "$work/nowhere" --submission "$app_id"

    rm -rf "$work/notary-out" "$work/state"
    expect_fail "a rejected app fails" notarize STUB_NOTARY=invalid -- --output "$work/notary-out" --state-dir "$work/state"
    expect_ok "with Apple's log" grep -q "^xcrun notarytool log $app_id" "$work/stub.log"
    expect_ok "and nothing pending" test ! -e "$work/state/pending.json"
    rm -rf "$work/notary-out" "$work/state"
    expect_ok "a DMG that isn't notarized in time is left out" notarize STUB_NOTARY=accepted STUB_NOTARY_DMG=slow -- --output "$work/notary-out" --state-dir "$work/state"
    expect_eq "the release ships the ZIP" "Daybook-1.4.0-macOS-arm64.zip SHA256SUMS.txt" "$(files_in "$work/notary-out")"

    # Cloud-managed signing leaves no Developer ID identity in a keychain: the release is the ZIP alone, with its checksums.
    rm -rf "$work/notary-out" "$work/state"
    expect_ok "without a Developer ID identity, with the team set" notarize STUB_NOTARY=accepted STUB_IDENTITY=0 -- \
        --output "$work/notary-out" --state-dir "$work/state"
    expect_eq "ships the ZIP and its checksums" "Daybook-1.4.0-macOS-arm64.zip SHA256SUMS.txt" "$(files_in "$work/notary-out")"
    expect_ok "and says why there's no DMG" grep -q "No Developer ID identity in a keychain" "$work/package.out"
    expect_eq "(nothing but the app went to Apple)" "1" "$(grep -c '^xcrun notarytool submit' "$work/stub.log")"
    rm -rf "$work/notary-out" "$work/state"
    expect_ok "another team's identity signs nothing" notarize STUB_NOTARY=accepted STUB_IDENTITY_TEAM=ZZZZZZZZZZ -- \
        --output "$work/notary-out" --state-dir "$work/state"
    expect_eq "(the ZIP alone)" "Daybook-1.4.0-macOS-arm64.zip SHA256SUMS.txt" "$(files_in "$work/notary-out")"
    expect_eq "(no DMG signed)" "" "$(grep -E '^codesign --sign' "$work/stub.log" || true)"

    # The App Sandbox: a release is exactly the kind it says (scripts/ci/check-mac-app.sh).
    # shellcheck disable=SC2016 # the entitlements file's own build settings, replaced literally
    sed -e 's/$(DAYBOOK_ICLOUD_CONTAINER)/iCloud.local.daybook/g' -e 's/$(DAYBOOK_APS_ENVIRONMENT)/production/g' \
        "$ci/../../Resources/Daybook-Sandbox.entitlements" > "$work/sandboxed.entitlements"
    rm -rf "$work/notary-out" "$work/state"
    expect_fail "--sandbox refuses an app that isn't sandboxed" notarize STUB_NOTARY=accepted -- --sandbox --output "$work/notary-out" --state-dir "$work/state"
    expect_eq "before anything goes to Apple" "" "$(grep -E '^xcrun notarytool submit' "$work/stub.log" || true)"
    expect_fail "a sandboxed app without the manifest" notarize STUB_NOTARY=accepted STUB_ENTITLEMENTS="$work/sandboxed.entitlements" -- \
        --sandbox --output "$work/notary-out" --state-dir "$work/state"
    mkdir -p "$work/pkg/Daybook.app/Contents/Resources"
    cp "$ci/../../Resources/container-migration.plist" "$work/pkg/Daybook.app/Contents/Resources/"
    plutil -replace CFBundleIdentifier -string local.daybook.app "$work/pkg/Daybook.app/Contents/Info.plist"
    expect_fail "a sandboxed release under the earlier bundle ID" notarize STUB_NOTARY=accepted \
        STUB_ENTITLEMENTS="$work/sandboxed.entitlements" -- --sandbox --output "$work/notary-out" --state-dir "$work/state"
    plutil -replace CFBundleIdentifier -string local.daybook "$work/pkg/Daybook.app/Contents/Info.plist"
    expect_ok "a sandboxed release with the manifest" notarize STUB_NOTARY=accepted STUB_ENTITLEMENTS="$work/sandboxed.entitlements" -- \
        --sandbox --output "$work/notary-out" --state-dir "$work/state"
    rm -rf "$work/notary-out" "$work/state"
    expect_fail "but not as an ordinary release" notarize STUB_NOTARY=accepted STUB_ENTITLEMENTS="$work/sandboxed.entitlements" -- \
        --output "$work/notary-out" --state-dir "$work/state"
    rm -f "$work/pkg/Daybook.app/Contents/Resources/container-migration.plist"
else
    skip "package-mac.sh (macOS only)"
fi

# --- select-xcode.sh, with stand-in tools ----------------------------------------------------------------
echo "select-xcode.sh"
fake_xcode="$work/Xcode_27.1.app"
mkdir -p "$fake_xcode/Contents/Developer"
select_xcode() {
    : > "$work/xcode-env"
    : > "$work/xcode-summary"
    env PATH="$stubs:$PATH" STUB_LOG="$work/stub.log" GITHUB_ENV="$work/xcode-env" GITHUB_STEP_SUMMARY="$work/xcode-summary" \
        "$@" > "$work/select-xcode.out" 2>&1
}
expect_ok "the expected Xcode" select_xcode "$ci/select-xcode.sh" --xcode "$fake_xcode" --sdk iphoneos27.1 --metal
expect_eq "is selected for later steps" "DEVELOPER_DIR=$fake_xcode/Contents/Developer DAYBOOK_XCODE_BUILD=27A9275" \
    "$(paste -sd ' ' - < "$work/xcode-env")"
expect_ok "the summary records Xcode" grep -qF -- "- Xcode 27.1 (27A9275)" "$work/xcode-summary"
expect_ok "and the Metal toolchain" grep -qF -- "- Metal toolchain 27A266a: Apple metal version" "$work/xcode-summary"
expect_ok "a release asserts the exact build" select_xcode "$ci/select-xcode.sh" --xcode "$fake_xcode" --expect-build 27A9275
expect_fail "and refuses another" select_xcode env STUB_XCODE_BUILD=27A9300 "$ci/select-xcode.sh" --xcode "$fake_xcode" --expect-build 27A9275
expect_ok "naming the variable to change" grep -q DAYBOOK_RELEASE_XCODE_BUILD "$work/select-xcode.out"
expect_ok "a patch release still matches 27.1" select_xcode env STUB_XCODE_VERSION=27.1.1 "$ci/select-xcode.sh" --xcode "$fake_xcode"
expect_fail "27.10 doesn't" select_xcode env STUB_XCODE_VERSION=27.10 "$ci/select-xcode.sh" --xcode "$fake_xcode"
expect_fail "a missing SDK fails" select_xcode "$ci/select-xcode.sh" --xcode "$fake_xcode" --sdk iphoneos28.0
expect_fail "a missing Xcode fails" select_xcode "$ci/select-xcode.sh" --xcode "$work/Xcode_none.app"

# --- secrets.sh -----------------------------------------------------------------------------------------
echo "secrets.sh"
secrets_env=(RUNNER_TEMP="$work/runner-temp" GITHUB_ENV="$work/github-env" ASC_KEY_ID=ABC123DEFG ASC_ISSUER_ID="$issuer"
             ASC_KEY_P8_BASE64="$(base64 < "$key" | tr -d '\n')" PATH="$stubs:$PATH" STUB_LOG="$work/stub.log")
mkdir -p "$work/runner-temp"
: > "$work/github-env"
# shellcheck disable=SC2016 # expanded by the inner shell, inside `run`
seen="$(env "${secrets_env[@]}" "$ci/secrets.sh" run -- bash -c \
    'printf "%s %s %s\n" "$DAYBOOK_ASC_KEY_ID" "$(ls -ld "$DAYBOOK_ASC_KEY_PATH" | cut -c1-10)" "$(ls -ld "$(dirname "$DAYBOOK_ASC_KEY_PATH")" | cut -c1-10)"; echo "$DAYBOOK_ASC_KEY_PATH" > "'"$work"'/key-path"' 2>/dev/null)"
expect_eq "run: the command sees the key, mode 600 in a 700 directory" "ABC123DEFG -rw------- drwx------" "$seen"
expect_ok "named AuthKey_<id>.p8" grep -q '/daybook-secrets/AuthKey_ABC123DEFG.p8$' "$work/key-path"
expect_ok "and it's gone afterwards" test ! -e "$(cat "$work/key-path")" -a ! -e "$work/runner-temp/daybook-secrets"
expect_eq "nothing reaches GITHUB_ENV" "" "$(cat "$work/github-env")"
# The command gets the files, never the secrets they came from: compilers, plugins, and macros inherit its environment.
raw_secrets='ASC_KEY_P8_BASE64|DEVELOPER_ID_P12_BASE64|DEVELOPER_ID_P12_PASSWORD|DEVELOPMENT_P12_BASE64|DEVELOPMENT_P12_PASSWORD'
env "${secrets_env[@]}" "$ci/secrets.sh" run -- env > "$work/child-env" 2>/dev/null
expect_eq "the command's environment holds no raw secret" "" "$(cut -d= -f1 "$work/child-env" | grep -xE "$raw_secrets" || true)"
expect_eq "nor the key's text under another name" "0" \
    "$(grep -cF -- "$(base64 < "$key" | tr -d '\n' | cut -c1-48)" "$work/child-env" || true)"
expect_ok "only the key's file" grep -q '^DAYBOOK_ASC_KEY_PATH=' "$work/child-env"
status=0
env "${secrets_env[@]}" "$ci/secrets.sh" run -- sh -c 'exit 7' 2>/dev/null || status=$?
expect_eq "the command's exit status comes through" "7" "$status"
expect_ok "and the files are still removed" test ! -e "$work/runner-temp/daybook-secrets"
expect_eq "the command keeps the step's umask: only the secrets' files are private" "0022" \
    "$(umask 022; env "${secrets_env[@]}" "$ci/secrets.sh" run -- sh -c umask 2>/dev/null)"
expect_fail "a key that isn't a .p8 fails" env "${secrets_env[@]}" ASC_KEY_P8_BASE64="$(printf 'nope' | base64)" "$ci/secrets.sh" run -- true
expect_ok "leaving nothing behind" test ! -e "$work/runner-temp/daybook-secrets"
expect_ok "raw PEM is accepted too" env "${secrets_env[@]}" ASC_KEY_P8_BASE64="$(cat "$key")" "$ci/secrets.sh" run -- true
notes="$(env "${secrets_env[@]}" "$ci/secrets.sh" run -- true 2>&1 >/dev/null | grep -c 'no DEVELOP' || true)"
expect_eq "no signing-certificate notes for a command that doesn't archive" "0" "$notes"
notes="$(env "${secrets_env[@]}" "$ci/secrets.sh" run -- true --archive-only 2>&1 >/dev/null | grep -c 'no DEVELOP' || true)"
expect_eq "both for one that does" "2" "$notes"
expect_ok "setup (for later steps) writes GITHUB_ENV" env "${secrets_env[@]}" "$ci/secrets.sh" setup
expect_eq "with the key's path" "DAYBOOK_ASC_KEY_PATH=$work/runner-temp/daybook-secrets/AuthKey_ABC123DEFG.p8" "$(grep '^DAYBOOK_ASC_KEY_PATH=' "$work/github-env")"
expect_ok "cleanup removes it" env RUNNER_TEMP="$work/runner-temp" PATH="$stubs:$PATH" STUB_LOG="$work/stub.log" "$ci/secrets.sh" cleanup
expect_ok "(gone)" test ! -e "$work/runner-temp/daybook-secrets"
if macos; then
    # shellcheck disable=SC2016 # a literal $ in the password
    p12_password='pa ss"wo\rd $HOME '"'"'x'
    p12_env=("${secrets_env[@]}" DEVELOPER_ID_P12_BASE64="$(printf 'not really a p12' | base64)" DEVELOPER_ID_P12_PASSWORD="$p12_password"
             STUB_IDENTITY=1)
    : > "$work/stub.log"
    : > "$work/stub.log.args"
    # shellcheck disable=SC2016 # expanded by the inner shell, inside `run`
    expect_ok "run with the .p12: a keychain with the identity" env "${p12_env[@]}" "$ci/secrets.sh" run -- \
        bash -c 'test -f "$DAYBOOK_SIGNING_KEYCHAIN" && test ! -e "$(dirname "$DAYBOOK_SIGNING_KEYCHAIN")/developer-id.p12"'
    keychain_password="$(jq -r 'select(.[0] == "create-keychain") | .[2]' "$work/stub.log.args")"
    expect_eq "the .p12 password reaches security on stdin, intact" "$p12_password" \
        "$(jq -r 'select(.[0] == "import") | . as $a | ($a | index("-P")) as $i | $a[$i + 1]' "$work/stub.log.args")"
    expect_eq "so does the keychain password, for create, unlock, and the partition list" "3" \
        "$(grep -cF -- "$keychain_password" "$work/stub.log.args")"
    expect_eq "no password on any command line" "" \
        "$(grep '^security ' "$work/stub.log" | grep -F -e "$keychain_password" -e 'wo\rd' || true)"
    expect_ok "the keychain is deleted afterwards" grep -q '^security delete-keychain .*daybook-signing.keychain-db' "$work/stub.log"
    expect_ok "and the search list restored" grep -q '^security list-keychains -d user -s /Users/runner/Library/Keychains/login.keychain-db$' "$work/stub.log"
    expect_ok "(nothing left)" test ! -e "$work/runner-temp/daybook-secrets"
    expect_fail "a .p12 without a Developer ID identity fails" env "${p12_env[@]}" STUB_IDENTITY=0 "$ci/secrets.sh" run -- true
    expect_fail "a wrong .p12 password fails" env "${p12_env[@]}" STUB_IMPORT_FAILS=1 "$ci/secrets.sh" run -- true
    expect_ok "(nothing left)" test ! -e "$work/runner-temp/daybook-secrets"
    expect_fail "a password with a line break is refused" env "${p12_env[@]}" DEVELOPER_ID_P12_PASSWORD="$(printf 'a\nb')" "$ci/secrets.sh" run -- true

    # The team's one development certificate: archives sign with it instead of creating one.
    dev_env=("${secrets_env[@]}" DEVELOPMENT_P12_BASE64="$(printf 'not really a p12 either' | base64)"
             DEVELOPMENT_P12_PASSWORD='dev "pass" \word' STUB_DEVELOPMENT_IDENTITY=1)
    : > "$work/stub.log"
    : > "$work/stub.log.args"
    # shellcheck disable=SC2016 # expanded by the inner shell, inside `run`
    expect_ok "run with the development .p12: a keychain with the identity" env "${dev_env[@]}" "$ci/secrets.sh" run -- \
        bash -c 'test -f "$DAYBOOK_SIGNING_KEYCHAIN" && test ! -e "$(dirname "$DAYBOOK_SIGNING_KEYCHAIN")/development.p12"'
    expect_eq "its password reaches security on stdin, intact" 'dev "pass" \word' \
        "$(jq -r 'select(.[0] == "import") | . as $a | ($a | index("-P")) as $i | $a[$i + 1]' "$work/stub.log.args")"
    expect_eq "without the Developer ID intermediate" "" "$(grep 'DeveloperIDG2CA' "$work/stub.log" || true)"
    expect_ok "but with the one development certificates chain through" grep -q '^curl .*AppleWWDRCAG3.cer' "$work/stub.log"
    expect_ok "(nothing left)" test ! -e "$work/runner-temp/daybook-secrets"
    : > "$work/stub.log.args"
    expect_ok "both .p12s go into one keychain" env "${p12_env[@]}" "${dev_env[@]}" "$ci/secrets.sh" run -- true
    expect_eq "(one keychain, two imports)" "1 2" \
        "$(jq -r '.[0]' "$work/stub.log.args" | grep -c '^create-keychain$') $(jq -r '.[0]' "$work/stub.log.args" | grep -c '^import$')"
    env "${p12_env[@]}" "${dev_env[@]}" "$ci/secrets.sh" run -- env > "$work/child-env" 2>/dev/null
    expect_eq "neither .p12 nor its password reaches the command" "" \
        "$(cut -d= -f1 "$work/child-env" | grep -xE "$raw_secrets" || true)"
    expect_eq "(not even by value)" "0" \
        "$(grep -cF -e "$(printf 'not really a p12' | base64)" -e 'dev "pass" \word' -e 'pa ss"wo\rd' "$work/child-env" || true)"
    expect_ok "only the keychain they went into" grep -q '^DAYBOOK_SIGNING_KEYCHAIN=' "$work/child-env"
    # A development certificate that's wrong falls back to creating one, as before, with a warning in the summary.
    expect_ok "an expired or revoked development identity only warns" env "${dev_env[@]}" STUB_DEVELOPMENT_IDENTITY=0 "$ci/secrets.sh" run -- true
    expect_ok "so does a wrong development password" env "${dev_env[@]}" STUB_IMPORT_FAILS=1 "$ci/secrets.sh" run -- true
    warned="$(env "${dev_env[@]}" GITHUB_ACTIONS=true STUB_IMPORT_FAILS=1 "$ci/secrets.sh" run -- true 2>/dev/null)"
    expect_ok "(a ::warning:: in the run)" grep -q '^::warning::couldn.t import the development .p12' <<< "$warned"
    expect_ok "and a missing development password" env "${dev_env[@]}" DEVELOPMENT_P12_PASSWORD= "$ci/secrets.sh" run -- true
    expect_ok "(nothing left)" test ! -e "$work/runner-temp/daybook-secrets"
    expect_fail "but a Developer ID .p12 that's wrong still fails" env "${p12_env[@]}" "${dev_env[@]}" STUB_IDENTITY=0 "$ci/secrets.sh" run -- true
else
    skip "secrets.sh with a .p12 (macOS only)"
fi

# --- The app icon: one layered Icon Composer document for both apps ----------------------------------------
echo "app icon"
icon="$ci/../../Resources/Daybook.icon"
missing=""
for image in $(jq -r '.groups[].layers[]."image-name"' "$icon/icon.json"); do
    [[ -s "$icon/Assets/$image" ]] || missing="$missing $image"
done
expect_eq "every layer icon.json names is in Assets (scripts/make-icon.swift)" "" "${missing# }"
expect_eq "with the tile's gradient as its background, in Dark too" "2 2" \
    "$(jq -r '[.["fill-specializations"][].value."linear-gradient" | length] | map(tostring) | join(" ")' "$icon/icon.json")"
for spec in Apps/macOS/project.yml Apps/iOS/project.yml; do
    expect_ok "$spec builds it as the app icon" grep -q '^ *- path: \.\./\.\./Resources/Daybook\.icon$' "$ci/../../$spec"
    expect_ok "(named Daybook)" grep -q '^ *ASSETCATALOG_COMPILER_APPICON_NAME: Daybook$' "$ci/../../$spec"
done
expect_eq "and no other app icon" "" \
    "$(find "$ci/../../Apps" "$ci/../../Resources" -name build -prune -o -name '*.appiconset' -print 2>/dev/null)"

# --- Pipelines: no reader that stops early after a pipe ----------------------------------------------------
# Under pipefail, `tool | grep -q`, `| head -1`, or an awk that exits at its first match can stop reading while the
# tool still writes; the tool then dies of SIGPIPE and the pipeline fails though the match was found (57ed5eb). The
# scripts read a tool's output whole and match it from a here-string instead.
echo "pipelines"
early_exit='(^|[^|])\|[[:space:]]*(head([[:space:]]|$)|grep[[:space:]]+(-[[:alnum:]]*[qm]|--quiet|--max-count)|awk[^|]*[^[:alnum:]_]exit([^[:alnum:]_]|$)|sed[[:space:]]+-n[^|]*q)'
for shape in "security find-identity -v | awk '/x/ { print \$2; exit }'" "swift --version 2>&1 | head -1" \
             "gh api x --jq y | grep -qxF z" "printf '%s' \"\$x\" | cut -f2 | grep -q y"; do
    expect_ok "the check catches: $shape" grep -qE "$early_exit" <<< "$shape"
done
for shape in "grep -q x <<< \"\$y\" || true" "awk '/x/ { print \$2; exit }' <<< \"\$y\"" "a || head=1" "sed -n 's/^x//p' file | sort"; do
    expect_fail "and lets this be: $shape" grep -qE "$early_exit" <<< "$shape"
done
readers="$(grep -nE "$early_exit" "$ci"/../*.sh "$ci"/../lib/*.sh "$ci"/*.sh "$ci"/lib/*.sh | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
expect_eq "no script has one" "" "$readers"

echo
echo "$passed passed, $failed failed, $skipped skipped"
if (( require_all && skipped )); then
    echo "--require-all: $skipped group(s) were skipped" >&2
    exit 1
fi
(( failed == 0 ))
