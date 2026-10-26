#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/../lib/macos.sh"
[[ ${BUILD_RUN_ID:-} =~ ^[1-9][0-9]*$ ]] || nw_fail 'Choose an original CI run ID.'
[[ -n ${GITHUB_REPOSITORY:-} && -n ${GITHUB_OUTPUT:-} && ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]*$ ]] || nw_fail 'GitHub workflow context is missing.'
[[ ${GITHUB_RUN_ATTEMPT:-1} == 1 ]] || nw_fail 'Workflow reruns may lose newer submission receipts. Start a new manual dispatch and recover from the latest completed distribution run.'
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
# A new workflow run otherwise starts with no local receipt and could upload the
# same candidate again. Even an early failed run requires explicit reconciliation.
gh api --paginate "repos/$GITHUB_REPOSITORY/actions/workflows/distribution.yml/runs?per_page=100" \
  --jq '.workflow_runs[]' | jq -s --arg build "$BUILD_RUN_ID" --arg current "$GITHUB_RUN_ID" \
  '[.[] | select(.id < ($current | tonumber) and .display_title == ("Notary Watch distribution from CI " + $build))]' > "$work/prior-runs.json"
if [[ -z ${RESUME_RUN_ID:-} ]]; then
  [[ $(jq length "$work/prior-runs.json") == 0 ]] || nw_fail 'This candidate already has a distribution run. Reconcile it and set resume_run_id; refusing a fresh upload.'
else
  [[ $RESUME_RUN_ID =~ ^[1-9][0-9]*$ && $RESUME_RUN_ID != "$GITHUB_RUN_ID" ]] || nw_fail 'Invalid recovery run ID.'
  latest=$(jq -er 'max_by(.id) | .id // empty' "$work/prior-runs.json") || nw_fail 'No earlier distribution run exists for this recovery candidate.'
  [[ $RESUME_RUN_ID == "$latest" ]] || nw_fail 'Recovery must use the latest earlier distribution attempt; an older checkpoint could lose submission IDs.'
fi
gh api --paginate "repos/$GITHUB_REPOSITORY/actions/runs/$BUILD_RUN_ID/artifacts?per_page=100" \
  --jq '.artifacts[]' | jq -s --arg run "$BUILD_RUN_ID" \
  '[.[] | select(.expired == false and (.name | test("^Notary-Watch-unsigned-" + $run + "-a[1-9][0-9]*$")))] | sort_by(.id) | last' > "$work/artifact.json"
artifact=$(jq -er '.id // empty' "$work/artifact.json") || nw_fail 'No retained universal installer artifact exists for this run.'
printf 'sha=%s\nrun_number=%s\nartifact_id=%s\n' "$sha" "$number" "$artifact" >> "$GITHUB_OUTPUT"
if [[ -n ${RESUME_RUN_ID:-} ]]; then
  validate_run "$RESUME_RUN_ID" '.github/workflows/distribution.yml'
  jq -e --arg build "$BUILD_RUN_ID" \
    '.event == "workflow_dispatch" and .status == "completed" and .display_title == ("Notary Watch distribution from CI " + $build)' \
    "$work/run.json" >/dev/null || nw_fail 'Recovery must come from a completed manually dispatched distribution run for this candidate.'
  gh api --paginate "repos/$GITHUB_REPOSITORY/actions/runs/$RESUME_RUN_ID/artifacts?per_page=100" \
    --jq '.artifacts[]' | jq -s --arg build "$BUILD_RUN_ID" --arg run "$RESUME_RUN_ID" \
    '[.[] | select(.expired == false and (.name | test("^Notary-Watch-state-" + $build + "-r" + $run + "-a[1-9][0-9]*-s[0-4][0-9]$")))] | sort_by(.id) | last' > "$work/recovery.json"
  recovery=$(jq -er '.id // empty' "$work/recovery.json") || nw_fail 'No retained checkpoint exists for this build in the recovery run.'
  printf 'recovery_artifact_id=%s\n' "$recovery" >> "$GITHUB_OUTPUT"
fi
