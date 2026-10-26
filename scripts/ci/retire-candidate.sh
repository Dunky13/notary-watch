#!/bin/bash
# Explicit incident retirement preserves every previous byte and grants no retry.
set -euo pipefail
umask 077
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/../lib/macos.sh"
[[ $# == 1 && -f $1 && ! -L $1 ]] || nw_fail 'Usage: retire-candidate.sh bound-safe-retirement-record.json'
[[ ${GH_REPO:-} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && ${BUILD_SHA:-} =~ ^[a-f0-9]{40}$ && ${BUILD_RUN_ID:-} =~ ^[1-9][0-9]*$ ]] || nw_fail 'Exact repository and original CI source identity are required.'
execution=$(jq -er '.execution_run_id | select(type == "string" and test("^[1-9][0-9]*$"))' "$1") || nw_fail 'Retirement requires an exact failed distribution execution.'
jq -e --arg sha "$BUILD_SHA" --arg run "$BUILD_RUN_ID" --arg execution "$execution" \
  -f "$NW_ROOT/scripts/lib/retirement.jq" "$1" >/dev/null || nw_fail 'Retirement record is malformed or belongs to another candidate.'
work=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-retirement.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
tag="notary-state-ci-$BUILD_RUN_ID"
jq -S . "$1" > "$work/retired.json"
gh api "repos/$GH_REPO/actions/runs/$BUILD_RUN_ID" > "$work/build.json"
jq -e --arg repo "$GH_REPO" --arg sha "$BUILD_SHA" \
  '.path == ".github/workflows/ci.yml" and .head_branch == "main" and .event == "push" and
   .status == "completed" and .conclusion == "success" and .head_sha == $sha and
   .repository.full_name == $repo and .head_repository.full_name == $repo' \
  "$work/build.json" >/dev/null || nw_fail 'Retirement original build provenance is invalid.'
gh api "repos/$GH_REPO/actions/runs/$execution" > "$work/execution.json"
jq -e --arg repo "$GH_REPO" --arg build "$BUILD_RUN_ID" \
  '.path == ".github/workflows/distribution.yml" and .head_branch == "main" and .run_attempt == 1 and
   (.event == "workflow_run" or .event == "workflow_dispatch") and .status == "completed" and
   (.conclusion == "failure" or .conclusion == "timed_out") and
   .display_title == ("Notary Watch distribution from CI " + $build) and
   .repository.full_name == $repo and .head_repository.full_name == $repo' \
  "$work/execution.json" >/dev/null || nw_fail 'Retirement requires the failed trusted distribution for this candidate.'
gh api --paginate "repos/$GH_REPO/actions/workflows/distribution.yml/runs?per_page=100" --jq '.workflow_runs[]' |
  jq -s --arg build "$BUILD_RUN_ID" '[.[] | select(.display_title == ("Notary Watch distribution from CI " + $build))]
    | if length > 0 and all(.[]; (.run_number | type == "number" and . > 0 and . == floor)) then max_by(.run_number) else error("Missing execution ordering") end' \
    > "$work/latest.json"
[[ $(jq -er '.id | tostring' "$work/latest.json") == "$execution" ]] || nw_fail 'Only the latest failed distribution execution may retire this candidate.'
lookup() {
  gh api --paginate "repos/$GH_REPO/releases?per_page=100" --jq '.[]' |
    jq -s --arg tag "$tag" '[.[] | select(.tag_name == $tag)]' > "$work/releases.json"
  jq -e --arg sha "$BUILD_SHA" 'length == 1 and .[0].target_commitish == $sha and
    .[0].draft == true and .[0].prerelease == true and (.[0].id | type == "number" and . > 0) and
    (.[0].assets | type == "array")' "$work/releases.json" >/dev/null || nw_fail 'Retirement requires existing private custody for the exact source.'
}
download() {
  local id
  id=$(jq -er '[.[0].assets[] | select(.name == "retired.json")] |
    if length == 1 and (.[0].id | type == "number" and . > 0) then .[0].id else error("Ambiguous retirement asset") end' "$work/releases.json") || nw_fail 'Retirement asset is missing or ambiguous.'
  gh api -H 'Accept: application/octet-stream' "repos/$GH_REPO/releases/assets/$id" > "$work/remote.json"
  cmp -s "$work/retired.json" "$work/remote.json" || nw_fail 'Existing retirement differs; refusing overwrite.'
}
lookup
count=$(jq '[.[0].assets[] | select(.name == "retired.json")] | length' "$work/releases.json")
case $count in
  0) gh release upload "$tag" "$work/retired.json" --repo "$GH_REPO" ;;
  1) download ;;
  *) nw_fail 'Duplicate immutable retirement assets.' ;;
esac
lookup
download
printf 'Retired original CI %s at distribution %s. State preserved; no upload or publication authorized.\n' "$BUILD_RUN_ID" "$execution"
