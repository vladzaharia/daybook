#!/bin/bash
# Derives the release version and build number for both apps.
#
#   scripts/ci/version.sh --ref refs/tags/v1.4.0 --run-number 57 [--run-attempt 1] [--offset 1000]
#   scripts/ci/version.sh --ref refs/heads/main --version 1.4.0 --run-number 58
#
# Prints key=value lines (append them to $GITHUB_OUTPUT):
#   marketing_version  X.Y.Z, from the tag vX.Y.Z (or --version on a branch). MARKETING_VERSION, which
#                      becomes CFBundleShortVersionString in both apps and the widget extension.
#   build_number       offset + run number, e.g. 1057. CURRENT_PROJECT_VERSION, which becomes
#                      CFBundleVersion. Attempt 2, 3, ... of a run appends .attempt (1057.2), which still
#                      sorts above 1057 and below 1058, so a re-run never collides with a build App
#                      Store Connect already has. release.yml's iphone and mac jobs run this script
#                      themselves with their own github.run_attempt: "Re-run failed jobs" doesn't re-run
#                      `prepare`, so a number worked out there would repeat attempt 1's.
#   build_base         offset + run number, without the attempt
#   build_candidates   every number this run has used up to this attempt, oldest first
#                      ("1057 1057.2 1057.3"): what an earlier attempt may already have uploaded
#   tag                the tag name (vX.Y.Z[-suffix]) or empty on a branch
#   is_tag             true or false
#   prerelease         true when the tag has a suffix (v1.4.0-rc.1); the GitHub Release is marked so
#
# The run number comes from release.yml's own counter (github.run_number), which only grows. The offset
# (repository variable DAYBOOK_BUILD_NUMBER_OFFSET, default 1000) keeps CI builds above any build
# uploaded by hand from Xcode. If release.yml is ever renamed or recreated its counter restarts at 1:
# raise the offset above the last uploaded build number before the next release.
#
# Tags must be vX.Y.Z with plain integers (App Store Connect accepts at most three integer components),
# optionally followed by -suffix for a prerelease. Exit status 2 means the input was rejected.
set -euo pipefail

ref=""
version=""
run_number=""
run_attempt=1
offset=1000

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
fail() { echo "version.sh: $*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ref) ref="${2-}"; shift ;;
        --version) version="${2-}"; shift ;;
        --run-number) run_number="${2-}"; shift ;;
        --run-attempt) run_attempt="${2-}"; shift ;;
        --offset) offset="${2-}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "unknown option: $1" ;;
    esac
    shift
done

number='(0|[1-9][0-9]*)'
semver="^${number}\\.${number}\\.${number}\$"

is_count() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

[[ -n "$ref" ]] || fail "--ref is required (for example refs/tags/v1.2.3 or refs/heads/main)"
is_count "$run_number" || fail "--run-number must be a positive integer, got '${run_number}'"
is_count "$run_attempt" || fail "--run-attempt must be a positive integer, got '${run_attempt}'"
[[ "$offset" =~ ^(0|[1-9][0-9]*)$ ]] || fail "--offset must be a non-negative integer, got '${offset}'"
# Keep the arithmetic well inside 32 bits on any shell.
(( ${#run_number} <= 9 && ${#offset} <= 9 )) || fail "run number or offset is too large"
(( run_attempt <= 100 )) || fail "--run-attempt is too large"

tag=""
is_tag=false
prerelease=false
case "$ref" in
    refs/tags/*)
        tag="${ref#refs/tags/}"
        [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-[0-9A-Za-z.-]+)?$ ]] \
            || fail "tag '$tag' isn't vX.Y.Z or vX.Y.Z-suffix"
        from_tag="${BASH_REMATCH[1]}"
        [[ -n "${BASH_REMATCH[2]}" ]] && prerelease=true
        [[ "$from_tag" =~ $semver ]] || fail "tag '$tag' has a component with a leading zero"
        if [[ -n "$version" && "$version" != "$from_tag" ]]; then
            fail "--version $version doesn't match tag $tag"
        fi
        version="$from_tag"
        is_tag=true
        ;;
    refs/heads/*)
        [[ -n "$version" ]] || fail "a branch build needs --version X.Y.Z (the workflow's version input)"
        [[ "$version" =~ $semver ]] || fail "version '$version' isn't X.Y.Z with plain integers"
        ;;
    *)
        fail "unsupported ref '$ref': use a tag refs/tags/vX.Y.Z or a branch refs/heads/<name>"
        ;;
esac

base=$(( offset + run_number ))
build="$base"
candidates="$base"
for (( attempt = 2; attempt <= run_attempt; attempt++ )); do
    build="${base}.${attempt}"
    candidates+=" $build"
done

echo "marketing_version=$version"
echo "build_number=$build"
echo "build_base=$base"
echo "build_candidates=$candidates"
echo "tag=$tag"
echo "is_tag=$is_tag"
echo "prerelease=$prerelease"
