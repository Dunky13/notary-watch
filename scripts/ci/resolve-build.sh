#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/../lib/macos.sh"
[[ ${BUILD_RUN_ID:-} =~ ^[1-9][0-9]*$ ]] || nw_fail 'Choose an original CI run ID.'
[[ -n ${GITHUB_REPOSITORY:-} && -n ${GITHUB_OUTPUT:-} ]] || nw_fail 'GitHub workflow context is missing.'
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
validate_run() {
  local id=$1 path=$2
  gh api "repos/$GITHUB_REPOSITORY/actions/runs/$id" > "$work/run.json"
  jq -e --arg repo "$GITHUB_REPOSITORY" --arg path "$path" \
    '.head_branch == "main" and .path == $path and .repository.full_name == $repo and .head_repository.full_name == $repo' \
    "$work/run.json" >/dev/null || nw_fail 'Run is not from the expected main workflow and repository.'
}
validate_run "$BUILD_RUN_ID" '.github/workflows/ci.yml'
jq -e '.event == "push" and .status == "completed" and .conclusion == "success"' "$work/run.json" >/dev/null || nw_fail 'Original main-push CI has not succeeded.'
sha=$(jq -er '.head_sha | select(test("^[a-f0-9]{40}$"))' "$work/run.json")
number=$(jq -er '.run_number' "$work/run.json")
gh api --paginate "repos/$GITHUB_REPOSITORY/actions/runs/$BUILD_RUN_ID/artifacts?per_page=100" \
  --jq '.artifacts[]' | jq -s --arg run "$BUILD_RUN_ID" \
  '[.[] | select(.expired == false and (.name | test("^Notary-Watch-unsigned-" + $run + "-a[1-9][0-9]*$")))] | sort_by(.id) | last' > "$work/artifact.json"
artifact=$(jq -er '.id // empty' "$work/artifact.json") || nw_fail 'No retained universal installer artifact exists for this run.'
printf 'sha=%s\nrun_number=%s\nartifact_id=%s\n' "$sha" "$number" "$artifact" >> "$GITHUB_OUTPUT"
if [[ -n ${RESUME_RUN_ID:-} ]]; then
  [[ $RESUME_RUN_ID =~ ^[1-9][0-9]*$ && $RESUME_RUN_ID != "$GITHUB_RUN_ID" ]] || nw_fail 'Invalid recovery run ID.'
  validate_run "$RESUME_RUN_ID" '.github/workflows/distribution.yml'
  jq -e '.event == "workflow_dispatch"' "$work/run.json" >/dev/null || nw_fail 'Recovery must come from a manually dispatched distribution run.'
  gh api --paginate "repos/$GITHUB_REPOSITORY/actions/runs/$RESUME_RUN_ID/artifacts?per_page=100" \
    --jq '.artifacts[]' | jq -s --arg build "$BUILD_RUN_ID" --arg run "$RESUME_RUN_ID" \
    '[.[] | select(.expired == false and (.name | test("^Notary-Watch-state-" + $build + "-r" + $run + "-a[1-9][0-9]*-s[0-4][0-9]$")))] | sort_by(.id) | last' > "$work/recovery.json"
  recovery=$(jq -er '.id // empty' "$work/recovery.json") || nw_fail 'No retained checkpoint exists for this build in the recovery run.'
  printf 'recovery_artifact_id=%s\n' "$recovery" >> "$GITHUB_OUTPUT"
fi
