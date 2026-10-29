#!/bin/bash
# Turns the release secrets into short-lived files on the runner, and removes them afterwards.
#
#   scripts/ci/secrets.sh run -- COMMAND [ARGUMENTS...]
#                                    set up as below, run COMMAND with the outputs in its environment,
#                                    then clean up, whatever COMMAND's outcome (also on SIGINT/SIGTERM).
#                                    release.yml wraps each step that needs a secret in this, so the key
#                                    file and keychain exist only while that step runs.
#   scripts/ci/secrets.sh setup      write the App Store Connect API key; with a .p12 (Developer ID or
#                                    Apple Development), also create a temporary keychain and import it
#   scripts/ci/secrets.sh cleanup    delete the keychain (restoring the keychain search list) and the
#                                    files; safe to run more than once, and when setup never ran
#
# Inputs (environment; in release.yml these come from the `release` environment's secrets):
#   ASC_KEY_ID, ASC_ISSUER_ID     App Store Connect API key ID and issuer ID
#   ASC_KEY_P8_BASE64             the AuthKey_<id>.p8 file, base64-encoded (raw PEM is accepted too)
#   DEVELOPER_ID_P12_BASE64       optional fallback: Developer ID Application certificate and private
#   DEVELOPER_ID_P12_PASSWORD       key exported as .p12, base64-encoded, and its password
#   DEVELOPMENT_P12_BASE64        optional: the team's one Apple Development certificate and private key
#   DEVELOPMENT_P12_PASSWORD        (scripts/asc-development-certificate.sh), so archives sign with it
#                                   instead of creating a certificate on every run
#   DAYBOOK_SECRETS_DIR           where the files go (default $RUNNER_TEMP/daybook-secrets)
#
# Outputs (with `run`, exported to COMMAND; with `setup`, appended to $GITHUB_ENV when it's set,
# otherwise printed):
#   DAYBOOK_ASC_KEY_PATH, DAYBOOK_ASC_KEY_ID, DAYBOOK_ASC_ISSUER_ID   read by build-app.sh,
#                                   build-ios.sh, notarize.sh, and asc-testflight.sh
#   DAYBOOK_SIGNING_KEYCHAIN        the temporary keychain, only when a .p12 was imported
#
# The directory is mode 700 and every file 600. A .p12 is deleted as soon as it's imported; the
# keychain's random password exists only in this process and the keychain itself. Passwords reach
# `security` on its standard input (`security -i`), never on a command line, where `ps` would show them.
set -euo pipefail

dir="${DAYBOOK_SECRETS_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/daybook-secrets}"
keychain="$dir/daybook-signing.keychain-db"
search_list="$dir/keychain-search-list"
# Apple's Developer ID intermediate (G2). Certificates issued since 2021 chain through it, and macOS
# ships only the older one, so codesign can't build the chain without it.
g2_url="https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer"
g2_sha256="f16cd3c54c7f83cea4bf1a3e6a0819c8aaa8e4a1528fd144715f350643d2df3a"
# Apple's Worldwide Developer Relations intermediate (G3), which Apple Development certificates chain through.
wwdr_g3_url="https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer"
wwdr_g3_sha256="dcf21878c77f4198e4b4614f03d696d89c66c66008d4244e1b99161aac91601f"

fail() { echo "secrets.sh: $*" >&2; exit 1; }
note() { echo "secrets.sh: $*" >&2; }
# A warning in the run's summary as well, when it's a GitHub Actions run.
warn() {
    note "warning: $*"
    if [[ "${GITHUB_ACTIONS:-}" == true ]]; then echo "::warning::$*"; fi
}

in_process=0
export_env() {
    if (( in_process )); then
        export "$1=$2"
    elif [[ -n "${GITHUB_ENV:-}" ]]; then
        printf '%s=%s\n' "$1" "$2" >> "$GITHUB_ENV"
    else
        printf 'export %s=%q\n' "$1" "$2"
    fi
}

# sec_arg VALUE: VALUE quoted as one argument for `security -i`, which splits its input like a shell:
# inside double quotes, \\ and \" stand for \ and ".
sec_arg() {
    [[ "$1" != *$'\n'* ]] || fail "a keychain argument can't contain a line break"
    printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

# security_stdin COMMAND: runs one `security` command read from standard input. `security -i` exits 0
# even when the command fails, so its "<command>: returned <status>" line decides.
security_stdin() {
    local output
    if ! output="$(printf '%s\n' "$1" | security -i 2>&1)" \
        || printf '%s\n' "$output" | grep -qE ': returned -?[0-9]+$'; then
        printf '%s\n' "$output" >&2
        return 1
    fi
    if [[ -n "$output" ]]; then printf '%s\n' "$output"; fi
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
    fi
    if [[ -z "${DEVELOPMENT_P12_BASE64:-}" ]]; then
        note "no DEVELOPMENT_P12_BASE64: an archive creates a development certificate (scripts/asc-certificates.sh)"
    fi
    if [[ -n "${DEVELOPER_ID_P12_BASE64:-}" ]]; then
        : "${DEVELOPER_ID_P12_PASSWORD:?DEVELOPER_ID_P12_PASSWORD is required with DEVELOPER_ID_P12_BASE64}"
        [[ "$DEVELOPER_ID_P12_PASSWORD" != *$'\n'* ]] || fail "DEVELOPER_ID_P12_PASSWORD can't contain a line break"
    fi
    if [[ -n "${DEVELOPMENT_P12_BASE64:-}" && ( -z "${DEVELOPMENT_P12_PASSWORD:-}" || "$DEVELOPMENT_P12_PASSWORD" == *$'\n'* ) ]]; then
        warn "DEVELOPMENT_P12_PASSWORD is missing or has a line break; an archive creates a development certificate instead"
        DEVELOPMENT_P12_BASE64=""
    fi

    [[ -n "${DEVELOPER_ID_P12_BASE64:-}${DEVELOPMENT_P12_BASE64:-}" ]] || return 0
    [[ "$(uname)" == Darwin ]] || fail "a keychain needs macOS"

    local password
    password="$(openssl rand -hex 24)"
    security list-keychains -d user | sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*$//' > "$search_list"
    security delete-keychain "$keychain" 2>/dev/null || true
    security_stdin "create-keychain -p $(sec_arg "$password") $(sec_arg "$keychain")" \
        || fail "couldn't create the keychain"
    # Lock after two hours of inactivity, longer than any step that uses it; `run` deletes it sooner.
    security set-keychain-settings -ut 7200 "$keychain"
    security_stdin "unlock-keychain -p $(sec_arg "$password") $(sec_arg "$keychain")" \
        || fail "couldn't unlock the keychain"
    local current=()
    while IFS= read -r line; do [[ -n "$line" ]] && current+=("$line"); done < "$search_list"
    # (bash 3.2 treats an empty array as unset under `set -u`, hence the ${a[@]+...} form)
    security list-keychains -d user -s "$keychain" ${current[@]+"${current[@]}"}

    if [[ -n "${DEVELOPER_ID_P12_BASE64:-}" ]]; then
        import_p12 developer-id "$DEVELOPER_ID_P12_BASE64" "$DEVELOPER_ID_P12_PASSWORD" \
            || fail "couldn't import the Developer ID .p12 (is DEVELOPER_ID_P12_PASSWORD its password?)"
    fi
    # Without the development identity an archive still works: it creates a certificate, as before.
    local development=0
    if [[ -n "${DEVELOPMENT_P12_BASE64:-}" ]]; then
        if import_p12 development "$DEVELOPMENT_P12_BASE64" "$DEVELOPMENT_P12_PASSWORD"; then
            development=1
        else
            warn "couldn't import the development .p12 (is DEVELOPMENT_P12_PASSWORD its password?); an archive creates a development certificate instead"
        fi
    fi
    # Let codesign use the keys without a prompt.
    security_stdin "set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $(sec_arg "$password") $(sec_arg "$keychain")" >/dev/null \
        || fail "couldn't allow codesign to use the key"

    if [[ -n "${DEVELOPER_ID_P12_BASE64:-}" ]]; then
        intermediate DeveloperIDG2CA "$g2_url" "$g2_sha256" \
            || note "warning: couldn't fetch Apple's Developer ID G2 intermediate; signing works only if the certificate chains through the older one"
    fi
    if (( development )); then
        intermediate AppleWWDRCAG3 "$wwdr_g3_url" "$wwdr_g3_sha256" \
            || note "warning: couldn't fetch Apple's WWDR G3 intermediate; the development identity is valid only if the runner has it"
    fi

    local identities
    identities=$(security find-identity -v -p codesigning "$keychain")
    if [[ -n "${DEVELOPER_ID_P12_BASE64:-}" ]]; then
        printf '%s\n' "$identities" | grep -q '"Developer ID Application' \
            || fail "the Developer ID .p12 has no valid Developer ID Application identity: $identities"
    fi
    if (( development )) && ! printf '%s\n' "$identities" | grep -q '"Apple Development'; then
        warn "the development .p12 has no valid Apple Development identity (expired or revoked? scripts/asc-development-certificate.sh makes a new one); an archive creates a development certificate instead"
    fi
    export_env DAYBOOK_SIGNING_KEYCHAIN "$keychain"
    note "imported into $keychain:"
    printf '%s\n' "$identities" | grep -E '"(Developer ID Application|Apple Development)' >&2 || true
}

# intermediate NAME URL SHA256: one of Apple's intermediate certificates into the temporary keychain, when what
# the URL serves has that digest. Fails (returns 1) otherwise.
intermediate() {
    local certificate="$dir/$1.cer" status=0
    if curl -fsSL --retry 3 -o "$certificate" "$2" \
        && [[ "$(shasum -a 256 "$certificate" | awk '{print $1}')" == "$3" ]]; then
        security import "$certificate" -k "$keychain" >/dev/null 2>&1 || true
    else
        status=1
    fi
    /bin/rm -f "${certificate:?}"
    return "$status"
}

# import_p12 NAME BASE64 PASSWORD: one .p12 into the temporary keychain, deleted at once. Fails (returns 1) when
# security can't import it.
import_p12() {
    local p12="$dir/$1.p12" status=0
    decode_to "$p12" "$2"
    security_stdin "import $(sec_arg "$p12") -k $(sec_arg "$keychain") -f pkcs12 -P $(sec_arg "$3") -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild" >/dev/null \
        || status=1
    /bin/rm -f "${p12:?}"
    return "$status"
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

run() {
    [[ "${1-}" == -- ]] && shift
    (( $# )) || { echo "usage: $0 run -- COMMAND [ARGUMENTS...]" >&2; exit 2; }
    in_process=1
    # Leftovers of a step that was killed before it could clean up.
    cleanup 2>/dev/null
    trap 'cleanup' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    setup
    local status=0
    "$@" || status=$?
    exit "$status"
}

case "${1-}" in
    run) shift; run "$@" ;;
    setup) setup ;;
    cleanup) cleanup ;;
    *) echo "usage: $0 run -- COMMAND... | setup | cleanup" >&2; exit 2 ;;
esac
