#!/bin/bash
# Lists the "Created via API" Apple Development certificates that the release pipeline's archives leave
# on the team, and revokes the old ones when asked. Each fresh CI runner has no development certificate,
# so automatic signing with the App Store Connect API key creates one; nothing that ships is signed
# with them (docs/release.md, "Development certificates").
#
#   scripts/asc-certificates.sh [--older-than 30]             dry run: list them, change nothing
#   scripts/asc-certificates.sh [--older-than 30] --revoke    revoke the ones older than that
#
# Only development certificates (DEVELOPMENT, IOS_DEVELOPMENT, MAC_APP_DEVELOPMENT) named "Created via
# API" are considered; distribution and Developer ID certificates never are. A certificate's age is
# worked out from its expiration date: Apple Development certificates are valid for one year. The
# default of 30 days keeps any a release run may still be using.
#
# Environment: DAYBOOK_ASC_KEY_PATH, DAYBOOK_ASC_KEY_ID, DAYBOOK_ASC_ISSUER_ID (an Admin team key), and
# for tests ASC_API_BASE (default https://api.appstoreconnect.apple.com) and DAYBOOK_NOW (Unix time).
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
api="${ASC_API_BASE:-https://api.appstoreconnect.apple.com}"
older_than=30
revoke=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
fail() { echo "asc-certificates.sh: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --older-than) older_than="${2-}"; shift ;;
        --revoke) revoke=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; echo "asc-certificates.sh: unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
[[ "$older_than" =~ ^[0-9]+$ ]] || fail "--older-than takes a number of days"
: "${DAYBOOK_ASC_KEY_PATH:?set DAYBOOK_ASC_KEY_PATH}" "${DAYBOOK_ASC_KEY_ID:?set DAYBOOK_ASC_KEY_ID}" "${DAYBOOK_ASC_ISSUER_ID:?set DAYBOOK_ASC_ISSUER_ID}"
command -v jq >/dev/null || fail "jq is required"
now="${DAYBOOK_NOW:-$(date +%s)}"

work="$(mktemp -d)"
trap '/bin/rm -rf "${work:?}"' EXIT
chmod 700 "$work"
token="$("$script_dir/ci/asc-jwt.sh" --key "$DAYBOOK_ASC_KEY_PATH" --key-id "$DAYBOOK_ASC_KEY_ID" --issuer-id "$DAYBOOK_ASC_ISSUER_ID")"
# The token reaches curl through a header file readable only by this user, not the command line.
printf 'Authorization: Bearer %s\n' "$token" > "$work/headers"
chmod 600 "$work/headers"

# request METHOD URL: prints the HTTP status; the body goes to $work/body.
request() {
    local args=(-sS -X "$1" -H "@$work/headers" -H 'Accept: application/json' -o "$work/body" -w '%{http_code}'
                --connect-timeout 20 --max-time 120)
    [[ "$1" == GET ]] && args+=(--retry 3 --retry-delay 5)
    curl "${args[@]}" "$2" || echo 000
}
details() { jq -r '.errors[]? | "  \(.status) \(.code): \(.title) \(.detail // "")"' "$work/body" 2>/dev/null || true; }

# Every development certificate, following the pages.
url="$api/v1/certificates?filter%5BcertificateType%5D=DEVELOPMENT,IOS_DEVELOPMENT,MAC_APP_DEVELOPMENT"
url+="&fields%5Bcertificates%5D=name,displayName,certificateType,serialNumber,expirationDate&limit=200"
echo '[]' > "$work/all.json"
while [[ -n "$url" ]]; do
    status="$(request GET "$url")"
    [[ "$status" == 200 ]] || fail "HTTP $status listing certificates$(printf '\n%s' "$(details)")"
    jq -s '.[0] + .[1].data' "$work/all.json" "$work/body" > "$work/merged.json"
    mv "$work/merged.json" "$work/all.json"
    url="$(jq -r '.links.next // empty' "$work/body")"
done

# id, type, serial, expiration, age in days, for the ones the pipeline created.
jq -r --argjson now "$now" '
    def epoch: capture("^(?<dt>[0-9-]+T[0-9:]+)(\\.[0-9]+)?(?<tz>Z|[+-][0-9]{2}:?[0-9]{2})$")
        | ((.dt + "Z") | fromdateiso8601) - (if .tz == "Z" then 0 else (.tz
            | capture("(?<s>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})")
            | (if .s == "-" then -1 else 1 end) * ((.h | tonumber) * 3600 + (.m | tonumber) * 60)) end);
    .[] | select((.attributes.displayName // "") == "Created via API" or ((.attributes.name // "") | test("Created via API")))
        | select(.attributes.certificateType | IN("DEVELOPMENT", "IOS_DEVELOPMENT", "MAC_APP_DEVELOPMENT"))
        | [.id, .attributes.certificateType, (.attributes.serialNumber // "?"), .attributes.expirationDate,
           ((($now - ((.attributes.expirationDate | epoch) - 365 * 86400)) / 86400) | floor)] | @tsv' \
    "$work/all.json" > "$work/created.tsv"

total="$(grep -c . "$work/created.tsv" || true)"
old=0
revoked=0
printf '%-12s %-20s %-18s %-26s %5s  %s\n' ID TYPE SERIAL EXPIRES AGE ACTION
while IFS=$'\t' read -r id type serial expires age; do
    [[ -n "$id" ]] || continue
    action="keep"
    if (( age > older_than )); then
        old=$(( old + 1 ))
        action="revoke"
        if (( revoke )); then
            status="$(request DELETE "$api/v1/certificates/$id")"
            if [[ "$status" == 204 ]]; then
                action="revoked"
                revoked=$(( revoked + 1 ))
            else
                action="FAILED (HTTP $status)"
                details >&2
            fi
        fi
    fi
    printf '%-12s %-20s %-18s %-26s %4sd  %s\n' "$id" "$type" "$serial" "$expires" "$age" "$action"
done < "$work/created.tsv"

echo
echo "$total \"Created via API\" development certificate(s); $old older than $older_than days."
if (( revoke )); then
    echo "Revoked $revoked."
    (( revoked == old )) || fail "$(( old - revoked )) couldn't be revoked"
elif (( old )); then
    echo "Dry run: nothing was changed. Add --revoke to revoke those $old."
fi
