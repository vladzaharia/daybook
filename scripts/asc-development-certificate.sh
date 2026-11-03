#!/bin/bash
# Makes the team's one Apple Development certificate for the release pipeline and keeps it in each
# distribution channel's environment (`iOS TestFlight`, `Mac TestFlight`, `Mac download`), so each run's
# archives sign with it instead of creating a certificate (docs/release.md,
# "Development certificates"). For the owner, with the Admin key. Run it again before the certificate
# expires (a year): that replaces the secrets, and the old certificate can then be revoked.
#
#   scripts/asc-development-certificate.sh [--repo OWNER/NAME] [--environment NAME]...   (default: all three)
#
# In a directory only this user can read, deleted at the end, it:
#   1. makes a 2048-bit RSA key and a certificate signing request
#   2. asks App Store Connect for an Apple Development certificate (POST /v1/certificates)
#   3. packs the certificate and the key as a .p12 with a random password, and checks that macOS imports it
#      with an Apple Development identity
#   4. stores the .p12 and its password as each environment's DEVELOPMENT_P12_BASE64 and
#      DEVELOPMENT_P12_PASSWORD secrets, through gh's standard input, never a command line, and the
#      certificate's ID as the repository variable DAYBOOK_DEVELOPMENT_CERTIFICATE_ID, which
#      scripts/asc-certificates.sh never revokes
# If anything after step 2 fails, the new certificate is revoked again.
#
# Environment: DAYBOOK_ASC_KEY_PATH, DAYBOOK_ASC_KEY_ID, DAYBOOK_ASC_ISSUER_ID (an Admin team key), and
# for tests ASC_API_BASE (default https://api.appstoreconnect.apple.com).
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
# asc_request, asc_details, sec_arg, and security_stdin.
# shellcheck source=ci/lib/asc.sh
source "$script_dir/ci/lib/asc.sh"
repo=""
environments=()

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
fail() { echo "asc-development-certificate.sh: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) repo="${2-}"; shift ;;
        --environment) environments+=("${2-}"); shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; echo "asc-development-certificate.sh: unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
: "${DAYBOOK_ASC_KEY_PATH:?set DAYBOOK_ASC_KEY_PATH}" "${DAYBOOK_ASC_KEY_ID:?set DAYBOOK_ASC_KEY_ID}" "${DAYBOOK_ASC_ISSUER_ID:?set DAYBOOK_ASC_ISSUER_ID}"
for tool in jq openssl gh security; do command -v "$tool" >/dev/null || fail "$tool is required"; done
(( ${#environments[@]} )) || environments=("iOS TestFlight" "Mac TestFlight" "Mac download")
for environment in "${environments[@]}"; do [[ -n "$environment" ]] || fail "--environment needs a name"; done
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
        asc_request DELETE "$asc_api/v1/certificates/$created" || true
        [[ "$asc_status" == 204 ]] \
            || echo "asc-development-certificate.sh: couldn't revoke $created; revoke it in Certificates, Identifiers & Profiles" >&2
    fi
    security delete-keychain "$work/check.keychain-db" 2>/dev/null || true
    /bin/rm -rf "${work:?}"
    exit "$status"
}
trap finish EXIT
# The token's header file and the responses.
asc_dir="$work"

# 1. The key and the request.
openssl genrsa -out "$work/key.pem" 2048 2>/dev/null || fail "couldn't make a key"
openssl req -new -key "$work/key.pem" -subj "/CN=Daybook release pipeline" -out "$work/request.csr" \
    || fail "couldn't make a certificate signing request"

# 2. The certificate.
asc_request POST "$asc_api/v1/certificates" "$(jq -n --rawfile csr "$work/request.csr" \
    '{data: {type: "certificates", attributes: {certificateType: "DEVELOPMENT", csrContent: $csr}}}')"
[[ "$asc_status" == 201 ]] || fail "HTTP $asc_status making the certificate$(printf '\n%s' "$(asc_details)")"
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
security_stdin "create-keychain -p $(sec_arg "$check_password") $(sec_arg "$check")" >/dev/null \
    || fail "couldn't make a keychain to check the .p12"
security_stdin "import $(sec_arg "$work/development.p12") -k $(sec_arg "$check") -f pkcs12 -P $(sec_arg "$(cat "$work/password")")" >/dev/null \
    || fail "macOS couldn't import the .p12"
# Read in full before matching: piped into grep -q, security can still be writing its count line when grep
# exits, and pipefail then reports SIGPIPE as no identity.
identities="$(security find-identity -p codesigning "$check")" || fail "macOS couldn't list the .p12's identities"
grep -q '"Apple Development' <<< "$identities" || fail "the .p12 has no Apple Development identity"
security delete-keychain "$check" 2>/dev/null || true

# 4. The secrets and the variable.
previous="$(gh variable get DAYBOOK_DEVELOPMENT_CERTIFICATE_ID --repo "$repo" 2>/dev/null || true)"
# Once one environment holds it, the certificate is kept; if a later one fails, run this again, which makes a
# new certificate for every channel.
for environment in "${environments[@]}"; do
    base64 < "$work/development.p12" | tr -d '\n' | gh secret set DEVELOPMENT_P12_BASE64 --env "$environment" --repo "$repo" \
        || fail "couldn't store DEVELOPMENT_P12_BASE64 in '$environment'"
    gh secret set DEVELOPMENT_P12_PASSWORD --env "$environment" --repo "$repo" < "$work/password" \
        || fail "couldn't store DEVELOPMENT_P12_PASSWORD in '$environment'"
    stored=1
done
gh variable set DAYBOOK_DEVELOPMENT_CERTIFICATE_ID --body "$created" --repo "$repo" \
    || echo "asc-development-certificate.sh: couldn't set DAYBOOK_DEVELOPMENT_CERTIFICATE_ID to $created; set it, or pass --keep $created to asc-certificates.sh" >&2

echo "The release pipeline's development certificate is now $created (serial $serial, expires $expires)."
printf "Stored as DEVELOPMENT_P12_BASE64 and DEVELOPMENT_P12_PASSWORD in %s's environments:" "$repo"
printf " '%s'" "${environments[@]}"
echo "."
if [[ -n "$previous" && "$previous" != "$created" ]]; then
    echo "The previous one, $previous, isn't used any more: scripts/asc-certificates.sh --older-than 0 --revoke revokes it with the other API-made ones."
fi
