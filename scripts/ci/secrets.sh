#!/bin/bash
# Turns the release secrets into short-lived files on the runner, and removes them afterwards.
#
#   scripts/ci/secrets.sh setup      write the App Store Connect API key; with a Developer ID .p12,
#                                    also create a temporary keychain and import it
#   scripts/ci/secrets.sh cleanup    delete the keychain (restoring the keychain search list) and the
#                                    files; safe to run more than once, and when setup never ran
#
# Inputs (environment; in release.yml these come from the `release` environment's secrets):
#   ASC_KEY_ID, ASC_ISSUER_ID     App Store Connect API key ID and issuer ID
#   ASC_KEY_P8_BASE64             the AuthKey_<id>.p8 file, base64-encoded (raw PEM is accepted too)
#   DEVELOPER_ID_P12_BASE64       optional fallback: Developer ID Application certificate and private
#   DEVELOPER_ID_P12_PASSWORD       key exported as .p12, base64-encoded, and its password
#   DAYBOOK_SECRETS_DIR           where the files go (default $RUNNER_TEMP/daybook-secrets)
#
# Outputs (appended to $GITHUB_ENV when it's set, otherwise printed):
#   DAYBOOK_ASC_KEY_PATH, DAYBOOK_ASC_KEY_ID, DAYBOOK_ASC_ISSUER_ID   read by build-app.sh,
#                                   build-ios.sh, notarize.sh, and asc-testflight.sh
#   DAYBOOK_SIGNING_KEYCHAIN        the temporary keychain, only when a .p12 was imported
#
# The directory is mode 700 and every file 600. The .p12 is deleted as soon as it's imported; the
# keychain's random password exists only in this process and the keychain itself.
set -euo pipefail

dir="${DAYBOOK_SECRETS_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/daybook-secrets}"
keychain="$dir/daybook-signing.keychain-db"
search_list="$dir/keychain-search-list"
# Apple's Developer ID intermediate (G2). Certificates issued since 2021 chain through it, and macOS
# ships only the older one, so codesign can't build the chain without it.
g2_url="https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer"
g2_sha256="f16cd3c54c7f83cea4bf1a3e6a0819c8aaa8e4a1528fd144715f350643d2df3a"

fail() { echo "secrets.sh: $*" >&2; exit 1; }
note() { echo "secrets.sh: $*" >&2; }

export_env() {
    if [[ -n "${GITHUB_ENV:-}" ]]; then
        printf '%s=%s\n' "$1" "$2" >> "$GITHUB_ENV"
    else
        printf 'export %s=%q\n' "$1" "$2"
    fi
}

decode_to() {
    # decode_to FILE VALUE: base64 (or PEM text, for the API key) into FILE.
    local file="$1" value="$2"
    if [[ "$value" == -----BEGIN* ]]; then
        printf '%s\n' "$value" > "$file"
    else
        printf '%s' "$value" | tr -d ' \n\r\t' | base64 -d > "$file" 2>/dev/null \
            || fail "couldn't base64-decode the secret for $(basename "$file")"
    fi
    chmod 600 "$file"
}

setup() {
    : "${ASC_KEY_ID:?ASC_KEY_ID is required (a secret in the release environment)}"
    : "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required}"
    : "${ASC_KEY_P8_BASE64:?ASC_KEY_P8_BASE64 is required}"
    [[ "$ASC_KEY_ID" =~ ^[A-Z0-9]{10}$ ]] || fail "ASC_KEY_ID should be the 10-character key ID"

    umask 077
    mkdir -p "$dir"
    chmod 700 "$dir"

    # Xcode and notarytool look for AuthKey_<id>.p8 by that name in some code paths; keep it.
    local key="$dir/AuthKey_$ASC_KEY_ID.p8"
    decode_to "$key" "$ASC_KEY_P8_BASE64"
    grep -q -- '-----BEGIN PRIVATE KEY-----' "$key" || fail "ASC_KEY_P8_BASE64 isn't a .p8 private key"
    openssl pkey -in "$key" -noout 2>/dev/null || fail "ASC_KEY_P8_BASE64 doesn't parse as a private key"
    export_env DAYBOOK_ASC_KEY_PATH "$key"
    export_env DAYBOOK_ASC_KEY_ID "$ASC_KEY_ID"
    export_env DAYBOOK_ASC_ISSUER_ID "$ASC_ISSUER_ID"
    note "App Store Connect API key $ASC_KEY_ID written to $key"

    if [[ -z "${DEVELOPER_ID_P12_BASE64:-}" ]]; then
        note "no DEVELOPER_ID_P12_BASE64: Developer ID signing uses Xcode's cloud-managed certificate"
        return 0
    fi
    [[ "$(uname)" == Darwin ]] || fail "a keychain needs macOS"
    : "${DEVELOPER_ID_P12_PASSWORD:?DEVELOPER_ID_P12_PASSWORD is required with DEVELOPER_ID_P12_BASE64}"

    local p12="$dir/developer-id.p12" password
    decode_to "$p12" "$DEVELOPER_ID_P12_BASE64"
    password="$(openssl rand -hex 24)"

    security list-keychains -d user | sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*$//' > "$search_list"
    security delete-keychain "$keychain" 2>/dev/null || true
    security create-keychain -p "$password" "$keychain"
    # Lock after six hours of inactivity, longer than any release job.
    security set-keychain-settings -ut 21600 "$keychain"
    security unlock-keychain -p "$password" "$keychain"
    local current=()
    while IFS= read -r line; do [[ -n "$line" ]] && current+=("$line"); done < "$search_list"
    # (bash 3.2 treats an empty array as unset under `set -u`, hence the ${a[@]+...} form)
    security list-keychains -d user -s "$keychain" ${current[@]+"${current[@]}"}

    security import "$p12" -k "$keychain" -f pkcs12 -P "$DEVELOPER_ID_P12_PASSWORD" \
        -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild >/dev/null
    /bin/rm -f "${p12:?}"
    # Let codesign use the key without a prompt.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null

    local g2="$dir/DeveloperIDG2CA.cer"
    if curl -fsSL --retry 3 -o "$g2" "$g2_url" \
        && [[ "$(shasum -a 256 "$g2" | awk '{print $1}')" == "$g2_sha256" ]]; then
        security import "$g2" -k "$keychain" >/dev/null 2>&1 || true
    else
        note "warning: couldn't fetch Apple's Developer ID G2 intermediate; signing works only if the certificate chains through the older one"
    fi
    /bin/rm -f "${g2:?}"

    local identities
    identities=$(security find-identity -v -p codesigning "$keychain")
    printf '%s\n' "$identities" | grep -q '"Developer ID Application' \
        || fail "the .p12 has no valid Developer ID Application identity: $identities"
    export_env DAYBOOK_SIGNING_KEYCHAIN "$keychain"
    note "imported into $keychain:"
    printf '%s\n' "$identities" | grep 'Developer ID' >&2
}

cleanup() {
    if [[ -f "$keychain" || -f "$search_list" ]] && command -v security >/dev/null; then
        if [[ -s "$search_list" ]]; then
            local previous=()
            while IFS= read -r line; do [[ -n "$line" ]] && previous+=("$line"); done < "$search_list"
            security list-keychains -d user -s ${previous[@]+"${previous[@]}"} || true
        fi
        security delete-keychain "$keychain" 2>/dev/null || true
        note "deleted the temporary keychain"
    fi
    if [[ -d "$dir" ]]; then
        /bin/rm -rf "${dir:?}"
        note "removed $dir"
    fi
}

case "${1-}" in
    setup) setup ;;
    cleanup) cleanup ;;
    *) echo "usage: $0 setup|cleanup" >&2; exit 2 ;;
esac
