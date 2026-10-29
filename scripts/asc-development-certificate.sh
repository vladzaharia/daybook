#!/bin/bash
# Makes the team's one Apple Development certificate for the release pipeline and keeps it in the release
# environment, so each run's archives sign with it instead of creating a certificate (docs/release.md,
# "Development certificates"). For the owner, with the Admin key. Run it again before the certificate
# expires (a year): that replaces the secrets, and the old certificate can then be revoked.
#
#   scripts/asc-development-certificate.sh [--repo OWNER/NAME] [--environment release]
#
# In a directory only this user can read, deleted at the end, it:
#   1. makes a 2048-bit RSA key and a certificate signing request
#   2. asks App Store Connect for an Apple Development certificate (POST /v1/certificates)
#   3. packs the certificate and the key as a .p12 with a random password, and checks that macOS imports it
#      with an Apple Development identity
#   4. stores the .p12 and its password as the environment's DEVELOPMENT_P12_BASE64 and
#      DEVELOPMENT_P12_PASSWORD secrets, through gh's standard input, never a command line, and the
#      certificate's ID as the repository variable DAYBOOK_DEVELOPMENT_CERTIFICATE_ID, which
#      scripts/asc-certificates.sh never revokes
# If anything after step 2 fails, the new certificate is revoked again.
#
# Environment: DAYBOOK_ASC_KEY_PATH, DAYBOOK_ASC_KEY_ID, DAYBOOK_ASC_ISSUER_ID (an Admin team key), and
# for tests ASC_API_BASE (default https://api.appstoreconnect.apple.com).
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
api="${ASC_API_BASE:-https://api.appstoreconnect.apple.com}"
repo=""
environment=release

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
fail() { echo "asc-development-certificate.sh: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) repo="${2-}"; shift ;;
        --environment) environment="${2-}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; echo "asc-development-certificate.sh: unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
: "${DAYBOOK_ASC_KEY_PATH:?set DAYBOOK_ASC_KEY_PATH}" "${DAYBOOK_ASC_KEY_ID:?set DAYBOOK_ASC_KEY_ID}" "${DAYBOOK_ASC_ISSUER_ID:?set DAYBOOK_ASC_ISSUER_ID}"
for tool in jq openssl gh security; do command -v "$tool" >/dev/null || fail "$tool is required"; done
[[ -n "$environment" ]] || fail "--environment needs a name"
if [[ -z "$repo" ]]; then
    repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || fail "pass --repo OWNER/NAME"
fi

umask 077
work="$(mktemp -d)"
chmod 700 "$work"
created=""
stored=0
finish() {
    local status=$?
    if [[ -n "$created" ]] && (( ! stored )); then
        echo "asc-development-certificate.sh: revoking $created, which wasn't stored" >&2
        [[ "$(request DELETE "$api/v1/certificates/$created")" == 204 ]] \
            || echo "asc-development-certificate.sh: couldn't revoke $created; revoke it in Certificates, Identifiers & Profiles" >&2
    fi
    security delete-keychain "$work/check.keychain-db" 2>/dev/null || true
    /bin/rm -rf "${work:?}"
    exit "$status"
}
trap finish EXIT

token="$("$script_dir/ci/asc-jwt.sh" --key "$DAYBOOK_ASC_KEY_PATH" --key-id "$DAYBOOK_ASC_KEY_ID" --issuer-id "$DAYBOOK_ASC_ISSUER_ID")"
# The token reaches curl through a header file readable only by this user, not the command line.
printf 'Authorization: Bearer %s\n' "$token" > "$work/headers"

# request METHOD URL [JSON_FILE]: prints the HTTP status; the body goes to $work/body.
request() {
    local args=(-sS -X "$1" -H "@$work/headers" -H 'Accept: application/json' -o "$work/body" -w '%{http_code}'
                --connect-timeout 20 --max-time 120)
    [[ -n "${3-}" ]] && args+=(-H 'Content-Type: application/json' --data-binary "@$3")
    curl "${args[@]}" "$2" || echo 000
}
details() { jq -r '.errors[]? | "  \(.status) \(.code): \(.title) \(.detail // "")"' "$work/body" 2>/dev/null || true; }

# sec_arg VALUE and security_stdin COMMAND, as in scripts/ci/secrets.sh: passwords reach `security` on its
# standard input, and its "<command>: returned <status>" line decides whether the command worked.
sec_arg() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"; }
security_stdin() {
    local output
    if ! output="$(printf '%s\n' "$1" | security -i 2>&1)" \
        || printf '%s\n' "$output" | grep -qE ': returned -?[0-9]+$'; then
        printf '%s\n' "$output" >&2
        return 1
    fi
}

# 1. The key and the request.
openssl genrsa -out "$work/key.pem" 2048 2>/dev/null || fail "couldn't make a key"
openssl req -new -key "$work/key.pem" -subj "/CN=Daybook release pipeline" -out "$work/request.csr" \
    || fail "couldn't make a certificate signing request"

# 2. The certificate.
jq -n --rawfile csr "$work/request.csr" \
    '{data: {type: "certificates", attributes: {certificateType: "DEVELOPMENT", csrContent: $csr}}}' > "$work/request.json"
status="$(request POST "$api/v1/certificates" "$work/request.json")"
[[ "$status" == 201 ]] || fail "HTTP $status making the certificate$(printf '\n%s' "$(details)")"
created="$(jq -r '.data.id // empty' "$work/body")"
[[ -n "$created" ]] || fail "App Store Connect made a certificate but didn't say its ID"
serial="$(jq -r '.data.attributes.serialNumber // "?"' "$work/body")"
expires="$(jq -r '.data.attributes.expirationDate // "?"' "$work/body")"
jq -r '.data.attributes.certificateContent // empty' "$work/body" | base64 -d > "$work/certificate.cer" 2>/dev/null \
    || fail "couldn't read the certificate App Store Connect returned"
openssl x509 -inform DER -in "$work/certificate.cer" -out "$work/certificate.pem" 2>/dev/null \
    || fail "the certificate App Store Connect returned doesn't parse"
[[ "$(openssl x509 -in "$work/certificate.pem" -noout -pubkey)" == "$(openssl pkey -in "$work/key.pem" -pubout)" ]] \
    || fail "the certificate isn't for this key"

# 3. The .p12, in the algorithms macOS's security reads, and a check that it imports with the identity.
openssl rand -hex 24 | tr -d '\n' > "$work/password"
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/certificate.pem" -name "Apple Development (release pipeline)" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -passout "file:$work/password" -out "$work/development.p12" \
    || fail "couldn't make the .p12"
check="$work/check.keychain-db"
check_password="$(openssl rand -hex 16)"
security_stdin "create-keychain -p $(sec_arg "$check_password") $(sec_arg "$check")" || fail "couldn't make a keychain to check the .p12"
security_stdin "import $(sec_arg "$work/development.p12") -k $(sec_arg "$check") -f pkcs12 -P $(sec_arg "$(cat "$work/password")")" \
    || fail "macOS couldn't import the .p12"
security find-identity -p codesigning "$check" | grep -q '"Apple Development' \
    || fail "the .p12 has no Apple Development identity"
security delete-keychain "$check" 2>/dev/null || true

# 4. The secrets and the variable.
previous="$(gh variable get DAYBOOK_DEVELOPMENT_CERTIFICATE_ID --repo "$repo" 2>/dev/null || true)"
base64 < "$work/development.p12" | tr -d '\n' | gh secret set DEVELOPMENT_P12_BASE64 --env "$environment" --repo "$repo" \
    || fail "couldn't store DEVELOPMENT_P12_BASE64"
gh secret set DEVELOPMENT_P12_PASSWORD --env "$environment" --repo "$repo" < "$work/password" \
    || fail "couldn't store DEVELOPMENT_P12_PASSWORD"
stored=1
gh variable set DAYBOOK_DEVELOPMENT_CERTIFICATE_ID --body "$created" --repo "$repo" \
    || echo "asc-development-certificate.sh: couldn't set DAYBOOK_DEVELOPMENT_CERTIFICATE_ID to $created; set it, or pass --keep $created to asc-certificates.sh" >&2

echo "The release pipeline's development certificate is now $created (serial $serial, expires $expires)."
echo "Stored as $repo's $environment secrets DEVELOPMENT_P12_BASE64 and DEVELOPMENT_P12_PASSWORD."
if [[ -n "$previous" && "$previous" != "$created" ]]; then
    echo "The previous one, $previous, isn't used any more: scripts/asc-certificates.sh --older-than 0 --revoke revokes it with the other API-made ones."
fi
