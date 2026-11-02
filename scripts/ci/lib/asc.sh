# shellcheck shell=bash
# shellcheck disable=SC2034 # the scripts that source this read its variables
#
# What the App Store Connect scripts share (scripts/asc-certificates.sh, scripts/asc-development-certificate.sh,
# scripts/ci/asc-profile.sh, scripts/ci/asc-testflight.sh), and the `security -i` helpers they and
# scripts/ci/secrets.sh use. Sourced, never run.
#
# The API calls need DAYBOOK_ASC_KEY_PATH, DAYBOOK_ASC_KEY_ID, and DAYBOOK_ASC_ISSUER_ID, and asc_dir: a directory only
# this user can read, which the caller makes and removes in its EXIT trap. The token reaches curl through a header file
# there (mode 600), never a command line, where `ps` would show it. ASC_API_BASE points the calls elsewhere (the tests'
# mock); the default is https://api.appstoreconnect.apple.com.

asc_api="${ASC_API_BASE:-https://api.appstoreconnect.apple.com}"
asc_jwt="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/asc-jwt.sh"
asc_dir=""
asc_token_time=0
asc_status=""
asc_body=""

# asc_bearer: a token in "$asc_dir/headers", made again after 15 minutes (tokens last 19).
asc_bearer() {
    [[ -n "$asc_dir" && -d "$asc_dir" ]] || { echo "asc.sh: asc_dir isn't set" >&2; return 1; }
    local now token
    now="$(date +%s)"
    if [[ -s "$asc_dir/headers" ]] && (( now - asc_token_time <= 900 )); then return 0; fi
    token="$("$asc_jwt" --key "$DAYBOOK_ASC_KEY_PATH" --key-id "$DAYBOOK_ASC_KEY_ID" --issuer-id "$DAYBOOK_ASC_ISSUER_ID")"
    (umask 077 && printf 'Authorization: Bearer %s\n' "$token" > "$asc_dir/headers")
    chmod 600 "$asc_dir/headers"
    asc_token_time="$now"
}

# asc_request METHOD URL [JSON]: one call to App Store Connect. Sets asc_status (000 when curl couldn't connect) and
# asc_body, which is also left in "$asc_dir/body". Only GETs are retried on transient errors: a retried POST or DELETE
# could act twice. Call it directly, never in $(...), so the token is made once for the process.
asc_request() {
    asc_bearer
    local args=(-sS -X "$1" -H "@$asc_dir/headers" -H 'Accept: application/json' -o "$asc_dir/body" -w '%{http_code}'
                --connect-timeout 20 --max-time 120)
    if [[ "$1" == GET ]]; then args+=(--retry 3 --retry-delay 5); fi
    if [[ -n "${3-}" ]]; then
        printf '%s' "$3" > "$asc_dir/request.json"
        args+=(-H 'Content-Type: application/json' --data-binary "@$asc_dir/request.json")
    fi
    : > "$asc_dir/body"
    asc_status="$(curl "${args[@]}" "$2")" || asc_status="000"
    asc_body="$(cat "$asc_dir/body")"
}

# asc_details: Apple's errors in the last body, one line each ("  409 ENTITY_ERROR: …"); nothing when there are none.
asc_details() {
    jq -r '.errors[]? | "  \(.status) \(.code): \(.title) \(.detail // "")"' "$asc_dir/body" 2>/dev/null || true
}

# asc_uri VALUE: VALUE percent-encoded for a query string.
asc_uri() { jq -rn --arg v "$1" '$v|@uri'; }

# sec_arg VALUE: VALUE quoted as one argument for `security -i`, which splits its input like a shell: inside double
# quotes, \\ and \" stand for \ and ". A line break can't be quoted: it prints nothing and fails.
sec_arg() {
    if [[ "$1" == *$'\n'* ]]; then
        echo "a keychain argument can't contain a line break" >&2
        return 1
    fi
    printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

# security_stdin COMMAND: runs one `security` command read from its standard input, so no password reaches a command
# line. `security -i` exits 0 even when the command fails, so its "<command>: returned <status>" line decides. Prints
# what security said: on success to standard output, on failure to standard error, returning 1.
security_stdin() {
    local output
    if ! output="$(printf '%s\n' "$1" | security -i 2>&1)" || grep -qE ': returned -?[0-9]+$' <<< "$output"; then
        printf '%s\n' "$output" >&2
        return 1
    fi
    if [[ -n "$output" ]]; then printf '%s\n' "$output"; fi
}
