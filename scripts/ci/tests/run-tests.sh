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
#   asc-testflight.sh     the full request sequence against a local mock of the App Store Connect API
#   asc-certificates.sh   the dry run and --revoke against the mock (fixture certificates)
#   release-notes.sh      annotated and lightweight tags in a throwaway repository
#   check-ref.sh          tags on and off main, manual runs, in a throwaway clone
#   github-release.sh     draft, re-run, publish, and refusal to touch a published release (fake gh)
#   prune-caches.sh       which caches go and which stay, against a fake gh
#   xcresult-retries.sh   passes on retry and flaky iterations, from xcresulttool fixtures
#   check-ios-archive.sh  synthetic archives: export compliance, icon, versions (macOS: needs plutil)
#   setup-github.sh       the dry run prints the plan and never calls gh
#   select-xcode.sh       version and exact-build checks, SDKs, and the summary, with stand-in tools
#   secrets.sh            run/setup/cleanup with the API key; on macOS, the .p12 keychain with a
#                         stand-in security that checks no password reaches a command line
#   build-ios.sh          the upload retry, package pinning, and archive calls, with stand-in Xcode tools
#                         (macOS)
#   build-app.sh          the xcodebuild calls and export options, with stand-in Xcode tools in a copy of
#                         the repository (macOS)
#   check-mac-app.sh      bundle IDs, App Sandbox entitlements, and migration manifests of each kind of build,
#                         on stand-in apps signed ad hoc with the repository's entitlements files (macOS)
#   package-mac.sh        version and build checks, ZIP, DMG, checksums, notarization waits, pending
#                         submissions, and notary-resume.sh, with stand-in tools (macOS)
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
expect_ok "an internal group with every build needs no assignment" env ASC_API_BASE="http://127.0.0.1:$port" ASC_POLL_SECONDS=0 \
    DAYBOOK_ASC_KEY_PATH="$key" DAYBOOK_ASC_KEY_ID=ABC123DEFG DAYBOOK_ASC_ISSUER_ID="$issuer" \
    "$ci/asc-testflight.sh" --bundle-id local.daybook.phone --version 1.4.0 --build 1057 --group "Daybook Internal"
expect_eq "nothing is added or submitted for review" "" \
    "$(jq -r 'select(.method == "POST" and (.path | test("relationships/builds|betaAppReviewSubmissions"))) | .path' "$log")"
: > "$log"
expect_fail "unknown group fails" env ASC_API_BASE="http://127.0.0.1:$port" ASC_POLL_SECONDS=0 \
    DAYBOOK_ASC_KEY_PATH="$key" DAYBOOK_ASC_KEY_ID=ABC123DEFG DAYBOOK_ASC_ISSUER_ID="$issuer" \
    "$ci/asc-testflight.sh" --bundle-id local.daybook.phone --version 1.4.0 --build 1057 --group "Nobody"
expect_fail "missing key fails" env -u DAYBOOK_ASC_KEY_PATH "$ci/asc-testflight.sh" --bundle-id x --version 1.0.0 --build 1
find_build() {
    ASC_API_BASE="http://127.0.0.1:$port" DAYBOOK_ASC_KEY_PATH="$key" DAYBOOK_ASC_KEY_ID=ABC123DEFG DAYBOOK_ASC_ISSUER_ID="$issuer" \
        "$ci/asc-testflight.sh" --bundle-id local.daybook.phone --version 1.4.0 "$@" 2>"$work/find.err"
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
certificates() {
    : > "$log"
    ASC_API_BASE="http://127.0.0.1:$port" DAYBOOK_NOW=1793000000 \
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
for needle in "environments/release" "deployment-branch-policies" "gh secret set ASC_KEY_P8_BASE64 --env release" \
              "gh secret set ASC_ISSUER_ID --env release" "DAYBOOK_TEAM_ID --body 48H7CLBV8Y" \
              "DAYBOOK_TESTFLIGHT_GROUP --body External\\ testers" "default_workflow_permissions=read" "rulesets" \
              "sha_pinning_required=true" "secret_scanning_push_protection" "automated-security-fixes"; do
    expect_ok "plan includes $needle" grep -qF -- "$needle" <<< "$plan"
done
key_body="$(sed '1d;$d' "$key" | tr -d '\n' | cut -c1-24)"
expect_fail "plan never prints the key" grep -qF -- "$key_body" <<< "$plan"
expect_fail "rejects a bad issuer" "$ci/setup-github.sh" --asc-key "$key" --asc-issuer-id nope
expect_fail "rejects a missing key" "$ci/setup-github.sh" --asc-key "$work/none.p8" --asc-issuer-id "$issuer"

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
    mkdir -p "$mac_repo/scripts" "$mac_repo/Apps/macOS/Config"
    cp "$ci/../build-app.sh" "$mac_repo/scripts/"
    cp "$ci/../../Package.resolved" "$mac_repo/"
    : > "$mac_repo/Apps/macOS/project.yml"
    # build_app [VAR=value...] -- ARGS: build-app.sh with only the given DAYBOOK_* variables.
    build_app() {
        local vars=()
        while [[ "$1" != -- ]]; do vars+=("$1"); shift; done
        shift
        : > "$work/stub.log"
        env -u DAYBOOK_TEAM_ID -u DAYBOOK_ASC_KEY_PATH -u DAYBOOK_ASC_KEY_ID -u DAYBOOK_ASC_ISSUER_ID \
            -u DAYBOOK_DEVELOPER_ID_PROFILE -u DAYBOOK_NOTARY_PROFILE -u DAYBOOK_MAC_DERIVED_DATA \
            -u DAYBOOK_REHEARSAL_BUNDLE_ID -u DAYBOOK_SANDBOX \
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
        grep -q -- 'DAYBOOK_SIGNING=rehearsal .*DAYBOOK_BUNDLE_ID_rehearsal=local.daybook.app.rehearsal' <<< "$(xcb ' build ')"
    expect_ok "another rehearsal from scratch" build_app DAYBOOK_REHEARSAL_BUNDLE_ID=local.daybook.app.rehearsal2 -- --sandbox-rehearsal --debug
    expect_ok "takes a new bundle ID" grep -q -- 'DAYBOOK_BUNDLE_ID_rehearsal=local.daybook.app.rehearsal2' <<< "$(xcb ' build ')"
    expect_fail "a rehearsal never takes the app's bundle ID" build_app DAYBOOK_REHEARSAL_BUNDLE_ID=local.daybook.app -- --sandbox-rehearsal
    expect_fail "and never changes the account" build_app DAYBOOK_TEAM_ID=48H7CLBV8Y -- --sandbox-rehearsal --allow-provisioning-updates
    expect_ok "an ad hoc release archive" build_app -- --ad-hoc
    expect_eq "is archived, not exported" "1 0" "$(xcb ' archive ' | wc -l | tr -d ' ') $(xcb '-exportArchive' | wc -l | tr -d ' ')"
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
        "$(plutil -extract signingStyle raw "$export_options") $(plutil -extract 'provisioningProfiles.local\.daybook\.app' raw "$export_options")"
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
    app="$(fake_app adhoc local.daybook.app.adhoc "$local_ent")"
    expect_ok "the ad hoc entitlements make a sandboxed ad hoc build" check_app --app "$app" --kind adhoc
    expect_fail "which isn't a signed build" check_app --app "$app" --kind signed
    expect_fail "an ad hoc build under the app's bundle ID" check_app --app "$(fake_app adhoc-id local.daybook.app "$local_ent")" --kind adhoc
    expect_ok "is refused for its bundle ID" grep -q "bundle ID is 'local.daybook.app'" "$work/check-app.out"
    expect_fail "an ad hoc build with a manifest" \
        check_app --app "$(fake_app adhoc-manifest local.daybook.app.adhoc "$local_ent" "$resources/container-migration.plist")" --kind adhoc
    expect_ok "is refused: it could move a library" grep -q "mustn't carry container-migration.plist" "$work/check-app.out"
    plutil -remove 'com\.apple\.security\.device\.bluetooth' -o "$work/no-bluetooth.entitlements" "$local_ent"
    expect_fail "a sandboxed build without Bluetooth" \
        check_app --app "$(fake_app no-bluetooth local.daybook.app.adhoc "$work/no-bluetooth.entitlements")" --kind adhoc
    plutil -replace 'com\.apple\.security\.temporary-exception\.files\.absolute-path\.read-write' -json '["/"]' \
        -o "$work/wide.entitlements" "$local_ent"
    expect_fail "an exception wider than /private/tmp/daybook/" \
        check_app --app "$(fake_app wide local.daybook.app.adhoc "$work/wide.entitlements")" --kind adhoc
    app="$(fake_app rehearsal local.daybook.app.rehearsal2 "$local_ent" "$resources/container-migration-rehearsal.plist")"
    expect_ok "a rehearsal build moves only the rehearsal's library" check_app --app "$app" --kind rehearsal
    expect_fail "a rehearsal with the real manifest" \
        check_app --app "$(fake_app rehearsal-real local.daybook.app.rehearsal "$local_ent" "$resources/container-migration.plist")" --kind rehearsal
    app="$(fake_app signed local.daybook.app "$resources/Daybook.entitlements")"
    expect_ok "the signed entitlements make an unsandboxed signed build" check_app --app "$app" --kind signed
    expect_fail "which isn't a sandboxed one" check_app --app "$app" --kind signed-sandbox
    expect_fail "a signed build with a manifest" \
        check_app --app "$(fake_app signed-manifest local.daybook.app "$resources/Daybook.entitlements" "$resources/container-migration.plist")" --kind signed
else
    skip "check-mac-app.sh (macOS only)"
fi

# --- build-ios.sh, with stand-in Xcode tools, in a copy of the repository ------------------------------
echo "build-ios.sh"
if macos; then
    ios_repo="$work/ios-repo"
    mkdir -p "$ios_repo/scripts" "$ios_repo/Apps/iOS/Config"
    cp "$ci/../build-ios.sh" "$ios_repo/scripts/"
    cp "$ci/../../Package.resolved" "$ios_repo/"
    : > "$ios_repo/Apps/iOS/project.yml"
    build_ios() {
        local vars=()
        while [[ "$1" != -- ]]; do vars+=("$1"); shift; done
        shift
        : > "$work/stub.log"
        env -u DAYBOOK_TEAM_ID -u DAYBOOK_ASC_KEY_PATH -u DAYBOOK_ASC_KEY_ID -u DAYBOOK_ASC_ISSUER_ID -u DAYBOOK_IOS_DERIVED_DATA \
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
    expect_ok "a device build never passes -allowProvisioningUpdates" build_ios DAYBOOK_TEAM_ID=48H7CLBV8Y -- --device
    expect_eq "(none in the calls)" "" "$(grep -- '-allowProvisioning' "$work/stub.log" || true)"
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
status=0
env "${secrets_env[@]}" "$ci/secrets.sh" run -- sh -c 'exit 7' 2>/dev/null || status=$?
expect_eq "the command's exit status comes through" "7" "$status"
expect_ok "and the files are still removed" test ! -e "$work/runner-temp/daybook-secrets"
expect_fail "a key that isn't a .p8 fails" env "${secrets_env[@]}" ASC_KEY_P8_BASE64="$(printf 'nope' | base64)" "$ci/secrets.sh" run -- true
expect_ok "leaving nothing behind" test ! -e "$work/runner-temp/daybook-secrets"
expect_ok "raw PEM is accepted too" env "${secrets_env[@]}" ASC_KEY_P8_BASE64="$(cat "$key")" "$ci/secrets.sh" run -- true
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
else
    skip "secrets.sh with a .p12 (macOS only)"
fi

echo
echo "$passed passed, $failed failed, $skipped skipped"
if (( require_all && skipped )); then
    echo "--require-all: $skipped group(s) were skipped" >&2
    exit 1
fi
(( failed == 0 ))
