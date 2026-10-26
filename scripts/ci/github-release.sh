#!/bin/bash
# Manages a tag's GitHub Release for release.yml: a draft first, published once every app is out.
#
#   scripts/ci/github-release.sh draft --repo OWNER/NAME --tag v1.4.0 --title "Daybook 1.4.0" \
#       --notes-file notes/release.md --prerelease false FILE...
#   scripts/ci/github-release.sh publish --repo OWNER/NAME --tag v1.4.0
#
# draft    creates the release as a draft with FILE... attached. If a draft for the tag exists (a
#          re-run), it's brought up to date: title, notes, and prerelease flag set again, assets that
#          aren't among FILE... deleted, FILE... uploaded over the old ones. A published release is
#          never changed: it fails, because people may already have the files (docs/release.md,
#          "Rolling back").
# publish  publishes the tag's draft. GitHub then marks a release that isn't a prerelease "Latest".
#          An already published release is left alone.
#
# Needs gh with GH_TOKEN (contents: write). Prints the release's URL on stdout.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
fail() { echo "github-release.sh: $*" >&2; exit 1; }
note() { echo "github-release.sh: $*" >&2; }

command="${1-}"
[[ "$command" == draft || "$command" == publish ]] || { usage >&2; exit 2; }
shift
repo=""
tag=""
title=""
notes_file=""
prerelease="false"
files=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) repo="${2-}"; shift ;;
        --tag) tag="${2-}"; shift ;;
        --title) title="${2-}"; shift ;;
        --notes-file) notes_file="${2-}"; shift ;;
        --prerelease) prerelease="${2-}"; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) usage >&2; fail "unknown option: $1" ;;
        *) files+=("$1") ;;
    esac
    shift
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "--repo must be OWNER/NAME"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || fail "--tag must be a release tag such as v1.4.0"
[[ "$prerelease" == true || "$prerelease" == false ]] || fail "--prerelease is true or false"

# state: "missing", "draft", or "published". gh finds a draft by the tag it will create.
state() {
    local draft
    if ! draft="$(gh release view "$tag" --repo "$repo" --json isDraft --jq .isDraft 2>/dev/null)"; then
        echo missing
    elif [[ "$draft" == true ]]; then
        echo draft
    else
        echo published
    fi
}

url() { gh release view "$tag" --repo "$repo" --json url --jq .url; }

case "$command" in
    draft)
        [[ -n "$title" ]] || fail "--title is required"
        [[ -r "$notes_file" ]] || fail "--notes-file must be a readable file"
        (( ${#files[@]} )) || fail "no files to attach"
        for file in "${files[@]}"; do [[ -f "$file" ]] || fail "no file $file"; done
        current="$(state)"
        case "$current" in
            missing)
                flags=(--repo "$repo" --draft --title "$title" --notes-file "$notes_file" --verify-tag)
                if [[ "$prerelease" == true ]]; then flags+=(--prerelease); fi
                gh release create "$tag" "${files[@]}" "${flags[@]}" >/dev/null
                note "created the draft release $tag"
                ;;
            draft)
                gh release edit "$tag" --repo "$repo" --title "$title" --notes-file "$notes_file" \
                    --prerelease="$prerelease" >/dev/null
                keep=""
                for file in "${files[@]}"; do keep+="$(basename "$file")"$'\n'; done
                assets="$(gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name')"
                while IFS= read -r asset; do
                    [[ -n "$asset" ]] || continue
                    if ! printf '%s' "$keep" | grep -qxF -- "$asset"; then
                        gh release delete-asset "$tag" "$asset" --repo "$repo" --yes
                        note "deleted $asset, which this run doesn't produce"
                    fi
                done <<< "$assets"
                gh release upload "$tag" "${files[@]}" --repo "$repo" --clobber
                note "updated the draft release $tag"
                ;;
            published)
                fail "$tag is already published, so its files aren't replaced: people may have downloaded them. To ship a fix, cut a new version. To redo this one, unpublish it first (docs/release.md, Rolling back), then re-run."
                ;;
        esac
        url
        ;;
    publish)
        current="$(state)"
        case "$current" in
            missing) fail "there's no draft release for $tag to publish" ;;
            published) note "$tag is already published" ;;
            draft)
                gh release edit "$tag" --repo "$repo" --draft=false >/dev/null
                note "published $tag"
                ;;
        esac
        url
        ;;
esac
