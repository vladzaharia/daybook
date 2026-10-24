#!/bin/bash
# Configures GitHub for the release pipeline: the `release` environment (required reviewers, main and
# v* tags only), its secrets, the repository variables, and Actions hardening. Prints the plan and
# changes nothing unless --apply is given.
#
#   scripts/ci/setup-github.sh --asc-key ~/keys/AuthKey_ABC123DEFG.p8 --asc-issuer-id <uuid> \
#       [--developer-id-p12 ~/keys/developer-id.p12] [--testflight-group "Daybook testers"] \
#       [--reviewer vladzaharia] [--protect-tags] [--apply]
#
# Options:
#   --repo OWNER/NAME          default vladzaharia/daybook
#   --asc-key FILE             the App Store Connect API key (.p8), downloaded once from App Store Connect
#   --asc-key-id ID            default: from the file name AuthKey_<ID>.p8
#   --asc-issuer-id UUID       App Store Connect › Users and Access › Integrations › Team Keys, "Issuer ID"
#   --developer-id-p12 FILE    optional fallback signing identity (docs/release.md, Signing). Its password
#                              comes from $DEVELOPER_ID_P12_PASSWORD, or a prompt with --apply.
#   --team-id ID               default 48H7CLBV8Y
#   --testflight-group NAME    beta group every release build is added to (variable; optional)
#   --build-offset N           added to the run number for CFBundleVersion (default 1000; scripts/ci/version.sh)
#   --reviewer LOGIN           who approves release runs (repeatable; default the repository owner)
#   --protect-tags             also add a tag ruleset: only admins create, move, or delete v* tags
#   --apply                    make the changes. Without it, nothing is sent to GitHub.
#
# Needs gh, authenticated as a repository admin (`gh auth status`). Secret values go to gh on stdin,
# never on a command line, and are never printed. Run it after the repository is public: required
# reviewers on an environment need a public repository (or a paid plan).
set -euo pipefail

repo="vladzaharia/daybook"
asc_key=""
asc_key_id=""
asc_issuer_id=""
p12=""
team_id="48H7CLBV8Y"
testflight_group=""
build_offset="1000"
reviewers=()
protect_tags=0
apply=0
environment="release"

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
fail() { echo "setup-github.sh: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) repo="${2-}"; shift ;;
        --asc-key) asc_key="${2-}"; shift ;;
        --asc-key-id) asc_key_id="${2-}"; shift ;;
        --asc-issuer-id) asc_issuer_id="${2-}"; shift ;;
        --developer-id-p12) p12="${2-}"; shift ;;
        --team-id) team_id="${2-}"; shift ;;
        --testflight-group) testflight_group="${2-}"; shift ;;
        --build-offset) build_offset="${2-}"; shift ;;
        --reviewer) reviewers+=("${2-}"); shift ;;
        --protect-tags) protect_tags=1 ;;
        --apply) apply=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "unknown option: $1" ;;
    esac
    shift
done

# --- Validate local inputs (nothing leaves this Mac here) -------------------------------------------
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "--repo must be OWNER/NAME"
[[ -n "$asc_key" ]] || { usage >&2; fail "--asc-key is required"; }
[[ -r "$asc_key" ]] || fail "can't read $asc_key"
grep -q -- '-----BEGIN PRIVATE KEY-----' "$asc_key" || fail "$asc_key isn't an App Store Connect .p8 key"
openssl pkey -in "$asc_key" -noout 2>/dev/null || fail "$asc_key doesn't parse as a private key"
if [[ -z "$asc_key_id" ]]; then
    base="$(basename "$asc_key")"
    [[ "$base" =~ ^AuthKey_([A-Z0-9]{10})\.p8$ ]] && asc_key_id="${BASH_REMATCH[1]}"
fi
[[ "$asc_key_id" =~ ^[A-Z0-9]{10}$ ]] || fail "pass --asc-key-id (the 10-character key ID)"
[[ "$asc_issuer_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
    || fail "--asc-issuer-id must be the issuer UUID"
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || fail "--team-id must be the 10-character team ID"
[[ "$build_offset" =~ ^(0|[1-9][0-9]{0,8})$ ]] || fail "--build-offset must be a non-negative integer"
if [[ -n "$p12" ]]; then
    [[ -r "$p12" ]] || fail "can't read $p12"
fi
(( ${#reviewers[@]} )) || reviewers=("${repo%%/*}")

# --- Plan and execution helpers ---------------------------------------------------------------------
step=0
say() { step=$(( step + 1 )); printf '\n%d. %s\n' "$step" "$*"; }
show() { printf '   $'; printf ' %q' "$@"; printf '\n'; }
# run CMD...: print it, and run it with --apply.
run() { show "$@"; if (( apply )); then "$@"; fi; }
# secret NAME DESCRIPTION: the value is read from the function `value_<NAME>` and piped to gh.
secret() {
    local name="$1" description="$2"
    printf '   $ <%s> | gh secret set %s --env %s --repo %s\n' "$description" "$name" "$environment" "$repo"
    if (( apply )); then
        "value_$name" | gh secret set "$name" --env "$environment" --repo "$repo"
    fi
}
value_ASC_KEY_ID() { printf '%s' "$asc_key_id"; }
value_ASC_ISSUER_ID() { printf '%s' "$asc_issuer_id"; }
value_ASC_KEY_P8_BASE64() { base64 < "$asc_key" | tr -d '\n'; }
value_DEVELOPER_ID_P12_BASE64() { base64 < "$p12" | tr -d '\n'; }
value_DEVELOPER_ID_P12_PASSWORD() { printf '%s' "$p12_password"; }

if (( apply )); then
    command -v gh >/dev/null || fail "gh is required: brew install gh"
    gh auth status >/dev/null 2>&1 || fail "run gh auth login first"
    visibility="$(gh repo view "$repo" --json visibility --jq .visibility)"
    if [[ "$visibility" != PUBLIC ]]; then
        echo "warning: $repo is $visibility. Make it public first: required reviewers on an environment need a public repository on GitHub Free, and macOS runner minutes are free only for public repositories." >&2
    fi
    p12_password="${DEVELOPER_ID_P12_PASSWORD:-}"
    if [[ -n "$p12" && -z "$p12_password" ]]; then
        read -r -s -p "Password for $p12: " p12_password
        echo
    fi
    if [[ -n "$p12" ]]; then
        [[ -n "$p12_password" ]] || fail "the .p12 needs its password"
        # Check the password before storing it (this reads the file locally only). Keychain Access
        # exports use ciphers OpenSSL 3 calls legacy; LibreSSL reads them without the flag.
        export DEVELOPER_ID_P12_PASSWORD="$p12_password"
        openssl pkcs12 -in "$p12" -passin env:DEVELOPER_ID_P12_PASSWORD -nokeys -noout 2>/dev/null \
            || openssl pkcs12 -legacy -in "$p12" -passin env:DEVELOPER_ID_P12_PASSWORD -nokeys -noout 2>/dev/null \
            || fail "the password doesn't open $p12"
    fi
    echo "Applying to $repo."
else
    p12_password=""
    echo "Dry run for $repo: printing the plan; nothing is changed. Add --apply to make these changes."
fi

# --- 1. Actions hardening ---------------------------------------------------------------------------
say "Actions: workflows get a read-only GITHUB_TOKEN by default and can't approve pull requests"
run gh api -X PUT "repos/$repo/actions/permissions/workflow" \
    -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false

say "Actions: every outside contributor's pull request waits for approval before workflows run"
show gh api -X PUT "repos/$repo/actions/permissions/fork-pr-contributor-approval" -f approval_policy=all_external_contributors
if (( apply )); then
    gh api -X PUT "repos/$repo/actions/permissions/fork-pr-contributor-approval" -f approval_policy=all_external_contributors \
        || echo "   warning: couldn't set it; set it in Settings › Actions › General › Approval for running fork pull request workflows" >&2
fi

# --- 2. The release environment -----------------------------------------------------------------------
say "Environment '$environment': required reviewers (${reviewers[*]}), deployments only from main and v* tags"
reviewer_json=""
for login in "${reviewers[@]}"; do
    show gh api "users/$login" --jq .id
    if (( apply )); then
        id="$(gh api "users/$login" --jq .id)"
    else
        id="<id of $login>"
    fi
    reviewer_json+="${reviewer_json:+,}{\"type\":\"User\",\"id\":${id}}"
done
environment_body="{\"wait_timer\":0,\"prevent_self_review\":false,\"reviewers\":[${reviewer_json}],\"deployment_branch_policy\":{\"protected_branches\":false,\"custom_branch_policies\":true}}"
printf "   \$ echo '%s' | gh api -X PUT repos/%s/environments/%s --input -\n" "$environment_body" "$repo" "$environment"
if (( apply )); then
    printf '%s' "$environment_body" | gh api -X PUT "repos/$repo/environments/$environment" --input - >/dev/null
fi

existing=""
show gh api "repos/$repo/environments/$environment/deployment-branch-policies" --jq '.branch_policies[] | "\(.type):\(.name)"'
if (( apply )); then
    existing="$(gh api "repos/$repo/environments/$environment/deployment-branch-policies" --jq '.branch_policies[] | "\(.type):\(.name)"')"
fi
for policy in "branch:main" "tag:v*"; do
    if printf '%s\n' "$existing" | grep -qxF "$policy"; then
        echo "   (policy $policy already exists)"
        continue
    fi
    run gh api -X POST "repos/$repo/environments/$environment/deployment-branch-policies" \
        -f name="${policy#*:}" -f type="${policy%%:*}" --silent
done

# --- 3. Secrets (environment-scoped: only approved release jobs can read them) -----------------------
say "Secrets in '$environment': the App Store Connect API key"
secret ASC_KEY_ID "$asc_key_id"
secret ASC_ISSUER_ID "issuer ID $asc_issuer_id"
secret ASC_KEY_P8_BASE64 "base64 of $asc_key"
if [[ -n "$p12" ]]; then
    say "Secrets in '$environment': the Developer ID fallback identity"
    secret DEVELOPER_ID_P12_BASE64 "base64 of $p12"
    secret DEVELOPER_ID_P12_PASSWORD "its password, from \$DEVELOPER_ID_P12_PASSWORD or a prompt"
else
    say "No --developer-id-p12: Developer ID signing will use Xcode's cloud-managed certificate (docs/release.md)"
fi

# --- 4. Variables ---------------------------------------------------------------------------------------
say "Repository variables"
run gh variable set DAYBOOK_TEAM_ID --body "$team_id" --repo "$repo"
run gh variable set DAYBOOK_BUILD_NUMBER_OFFSET --body "$build_offset" --repo "$repo"
if [[ -n "$testflight_group" ]]; then
    run gh variable set DAYBOOK_TESTFLIGHT_GROUP --body "$testflight_group" --repo "$repo"
else
    echo "   (no --testflight-group: builds are uploaded but not added to a group unless the run names one)"
fi

# --- 5. Optional tag protection -------------------------------------------------------------------------
if (( protect_tags )); then
    say "Tag ruleset: only repository admins create, move, or delete v* tags"
    ruleset='{"name":"Release tags","target":"tag","enforcement":"active","conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":[]}},"rules":[{"type":"creation"},{"type":"update"},{"type":"deletion"}],"bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]}'
    printf "   \$ echo '%s' | gh api -X POST repos/%s/rulesets --input -\n" "$ruleset" "$repo"
    if (( apply )); then
        if gh api "repos/$repo/rulesets" --jq '.[].name' | grep -qxF "Release tags"; then
            echo "   (ruleset 'Release tags' already exists)"
        else
            printf '%s' "$ruleset" | gh api -X POST "repos/$repo/rulesets" --input - --silent
        fi
    fi
fi

echo
if (( apply )); then
    echo "Done. Check Settings › Environments › $environment, then cut a release (docs/release.md)."
else
    echo "Nothing was changed. Re-run with --apply to make these changes."
fi
