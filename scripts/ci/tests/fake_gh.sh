#!/bin/bash
# A stand-in for gh's release commands, for scripts/ci/tests/run-tests.sh. Keeps one release's state in
# $GH_STATE: `state` (missing, draft, or published), `assets` (one name per line), `title`, and
# `prerelease`, and appends every call to `calls`. Never talks to GitHub.
set -euo pipefail
dir="${GH_STATE:?}"
printf '%s\n' "$*" >> "$dir/calls"
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
