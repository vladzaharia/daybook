#!/bin/bash
# A stand-in for gh, for scripts/ci/tests/run-tests.sh. Never talks to GitHub; appends every call to
# $GH_STATE/calls.
#   gh release ...   keeps one release's state in $GH_STATE: `state` (missing, draft, or published),
#                    `assets` (one name per line), `title`, and `prerelease`
#   gh api .../actions/caches[?ref=&key=] and -X DELETE .../actions/caches/<id>
#                    over $GH_STATE/caches, one "id<TAB>key<TAB>ref" per line
set -euo pipefail
dir="${GH_STATE:?}"
printf '%s\n' "$*" >> "$dir/calls"

if [[ "${1-}" == api ]]; then
    shift
    method=GET
    jq_filter="."
    path=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -X) method="$2"; shift ;;
            --jq) jq_filter="$2"; shift ;;
            --silent) ;;
            *) path="$1" ;;
        esac
        shift
    done
    case "$method $path" in
        "GET "*/actions/caches\?*)
            query="${path#*\?}"
            want_ref="$(printf '%s' "$query" | tr '&' '\n' | sed -n 's/^ref=//p')"
            want_key="$(printf '%s' "$query" | tr '&' '\n' | sed -n 's/^key=//p')"
            jq -R -s --arg ref "$want_ref" --arg key "$want_key" '
                {actions_caches: [split("\n")[] | select(length > 0) | split("\t")
                    | {id: (.[0] | tonumber), key: .[1], ref: .[2]}
                    | select(($ref == "" or .ref == $ref) and (.key | startswith($key)))]}' "$dir/caches" | jq -r "$jq_filter"
            ;;
        "DELETE "*/actions/caches/*)
            id="${path##*/}"
            grep -v "^$id"$'\t' "$dir/caches" > "$dir/caches.new" || true
            mv "$dir/caches.new" "$dir/caches"
            ;;
        *) echo "fake gh: unsupported: api $method $path" >&2; exit 2 ;;
    esac
    exit 0
fi

state="$(cat "$dir/state")"
[[ "${1-} ${2-}" == "release "* ]] || { echo "fake gh: unsupported: $*" >&2; exit 2; }
sub="$2"
tag="$3"
shift 3
# The positional arguments after the tag (files), then the flags.
positional=()
flags=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo|--title|--notes-file|--json|--jq) flags+=("$1" "$2"); shift ;;
        -*) flags+=("$1") ;;
        *) positional+=("$1") ;;
    esac
    shift
done
has_flag() { local f; for f in ${flags[@]+"${flags[@]}"}; do [[ "$f" == "$1" ]] && return 0; done; return 1; }
flag_value() { local i; for (( i = 0; i < ${#flags[@]}; i++ )); do [[ "${flags[$i]}" == "$1" ]] && { echo "${flags[$((i + 1))]}"; return; }; done; }
add_asset() { grep -qxF -- "$1" "$dir/assets" 2>/dev/null || echo "$1" >> "$dir/assets"; }

case "$sub" in
    view)
        [[ "$state" != missing ]] || { echo "release not found" >&2; exit 1; }
        case "$(flag_value --json)" in
            isDraft) [[ "$state" == draft ]] && echo true || echo false ;;
            assets) cat "$dir/assets" 2>/dev/null || true ;;
            url) echo "https://github.com/example/daybook/releases/tag/$tag" ;;
        esac
        ;;
    create)
        [[ "$state" == missing ]] || { echo "release exists" >&2; exit 1; }
        if has_flag --draft; then echo draft > "$dir/state"; else echo published > "$dir/state"; fi
        : > "$dir/assets"
        for file in ${positional[@]+"${positional[@]}"}; do add_asset "$(basename "$file")"; done
        flag_value --title > "$dir/title"
        if has_flag --prerelease; then echo true > "$dir/prerelease"; else echo false > "$dir/prerelease"; fi
        ;;
    edit)
        [[ "$state" != missing ]] || exit 1
        if has_flag --draft=false; then echo published > "$dir/state"; fi
        if [[ -n "$(flag_value --title)" ]]; then flag_value --title > "$dir/title"; fi
        if has_flag --prerelease=true; then echo true > "$dir/prerelease"; fi
        if has_flag --prerelease=false; then echo false > "$dir/prerelease"; fi
        ;;
    upload)
        [[ "$state" != missing ]] || exit 1
        for file in ${positional[@]+"${positional[@]}"}; do
            name="$(basename "$file")"
            if grep -qxF -- "$name" "$dir/assets" && ! has_flag --clobber; then echo "asset exists" >&2; exit 1; fi
            add_asset "$name"
        done
        ;;
    delete-asset)
        name="${positional[0]}"
        grep -vxF -- "$name" "$dir/assets" > "$dir/assets.new" || true
        mv "$dir/assets.new" "$dir/assets"
        ;;
    *) echo "fake gh: unsupported: release $sub" >&2; exit 2 ;;
esac
