#!/bin/bash
# Prints a JSON Web Token for the App Store Connect API, signed with an API key (ES256).
#
#   scripts/ci/asc-jwt.sh --key AuthKey_ABC123DEFG.p8 --key-id ABC123DEFG --issuer-id <uuid>
#   scripts/ci/asc-jwt.sh ... --issued-at 1767225600 --lifetime 600     (fixed time, for tests)
#
# Header {"alg":"ES256","kid":<key id>,"typ":"JWT"}; payload {"iss":<issuer id>,"iat":<now>,
# "exp":<now + lifetime>,"aud":"appstoreconnect-v1"}. Apple accepts a lifetime of at most 20 minutes;
# the default is 19. The signature is the raw 64-byte r || s that JWS requires, converted from the DER
# signature openssl produces. Needs only openssl (LibreSSL or OpenSSL), base64, sed, and awk.
#
# The key never leaves the file: it's read by openssl, and nothing here prints or logs it.
set -euo pipefail

key=""
key_id=""
issuer_id=""
issued_at=""
lifetime=1140

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
fail() { echo "asc-jwt.sh: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --key) key="${2-}"; shift ;;
        --key-id) key_id="${2-}"; shift ;;
        --issuer-id) issuer_id="${2-}"; shift ;;
        --issued-at) issued_at="${2-}"; shift ;;
        --lifetime) lifetime="${2-}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "unknown option: $1" ;;
    esac
    shift
done

[[ -r "$key" ]] || fail "--key must be a readable .p8 file"
[[ "$key_id" =~ ^[A-Z0-9]{10}$ ]] || fail "--key-id should be the 10-character key ID"
[[ "$issuer_id" =~ ^[0-9a-fA-F-]{36}$ ]] || fail "--issuer-id should be the issuer UUID"
if ! [[ "$lifetime" =~ ^[1-9][0-9]*$ ]] || (( lifetime > 1200 )); then
    fail "--lifetime must be 1-1200 seconds"
fi
if [[ -z "$issued_at" ]]; then
    issued_at=$(date +%s)
fi
[[ "$issued_at" =~ ^[0-9]+$ ]] || fail "--issued-at must be a Unix time"
expires=$(( issued_at + lifetime ))

base64url() { base64 | tr -d '\n=' | tr '/+' '_-'; }

header=$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$key_id" | base64url)
payload=$(printf '{"iss":"%s","iat":%d,"exp":%d,"aud":"appstoreconnect-v1"}' "$issuer_id" "$issued_at" "$expires" | base64url)
signing_input="$header.$payload"

# ECDSA-Sig-Value ::= SEQUENCE { r INTEGER, s INTEGER }. asn1parse prints each INTEGER as hex; each
# is left-padded (or stripped of its sign byte) to exactly 32 bytes.
integers=$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$key" \
    | openssl asn1parse -inform DER | awk -F: '/INTEGER/ { print $NF }') \
    || fail "openssl couldn't sign with $key (is it the .p8 from App Store Connect?)"
r_hex=$(printf '%s\n' "$integers" | sed -n 1p)
s_hex=$(printf '%s\n' "$integers" | sed -n 2p)

fixed32() {
    local hex
    hex=$(printf '%s' "$1" | tr 'a-f' 'A-F')
    while (( ${#hex} > 64 )) && [[ "$hex" == 00* ]]; do hex="${hex#00}"; done
    while (( ${#hex} < 64 )); do hex="0$hex"; done
    (( ${#hex} == 64 )) || fail "unexpected signature integer length"
    printf '%s' "$hex"
}

[[ "$r_hex" =~ ^[0-9A-Fa-f]+$ && "$s_hex" =~ ^[0-9A-Fa-f]+$ ]] || fail "couldn't read the signature"
r=$(fixed32 "$r_hex")
s=$(fixed32 "$s_hex")
# Hex to bytes with printf's \xHH escapes (no xxd on some Linux runners).
signature=$(printf '%b' "$(printf '%s%s' "$r" "$s" | sed 's/../\\x&/g')" | base64url)
printf '%s.%s\n' "$signing_input" "$signature"
