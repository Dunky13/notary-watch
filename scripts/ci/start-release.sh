#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/../lib/macos.sh"
cd "$NW_ROOT"
publish=false resume='' run=''
while [[ $# -gt 0 ]]; do
  case $1 in
    --publish) publish=true; shift ;;
    --resume) [[ $# -ge 2 ]] || nw_fail 'Pass the previous distribution run ID.'; resume=$2; shift 2 ;;
    --build-run-id) [[ $# -ge 2 ]] || nw_fail 'Pass the original CI run ID.'; run=$2; shift 2 ;;
    *) nw_fail 'Usage: start-release.sh [--publish] [--resume previous-distribution-run-id] [--build-run-id original-CI-run-id]' ;;
  esac
done
[[ -z $(git status --porcelain) ]] || nw_fail 'Release inputs require a clean checkout.'
sha=$(git rev-parse HEAD)
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
[[ $(gh api "repos/$repo/commits/main" --jq .sha) == "$sha" ]] || nw_fail 'Checkout must match the published main commit.'
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
if [[ -z $run ]]; then
  gh run list --repo "$repo" --workflow ci.yml --branch main --commit "$sha" --event push --limit 30 \
    --json databaseId,status,conclusion > "$work/builds.json"
  run=$(jq -er '[.[] | select(.status == "completed" and .conclusion == "success")] | first.databaseId' "$work/builds.json") || nw_fail 'No successful main-push CI run exists for this commit.'
fi
[[ $run =~ ^[1-9][0-9]*$ ]] || nw_fail 'No successful main-push CI run exists for this commit.'
gh api --paginate "repos/$repo/actions/workflows/distribution.yml/runs?per_page=100" \
  --jq '.workflow_runs[]' | jq -s --arg run "$run" \
  '[.[] | select(.display_title == ("Notary Watch distribution from CI " + $run))]' > "$work/distributions.json"
if [[ -z $resume ]]; then
  [[ $(jq length "$work/distributions.json") == 0 ]] || nw_fail 'This build already has a distribution run. Inspect it and use --resume with its ID; do not submit again.'
else
  [[ $resume =~ ^[1-9][0-9]*$ ]] || nw_fail 'Recovery run ID is invalid.'
  jq -e --arg id "$resume" 'any(.[]; (.id | tostring) == $id and .status == "completed")' \
    "$work/distributions.json" >/dev/null || nw_fail 'Recovery run must be completed and belong to this build.'
  [[ $(jq -r 'max_by(.id).id' "$work/distributions.json") == "$resume" ]] || nw_fail 'Recovery must use the latest distribution attempt; an older checkpoint can omit newer submissions.'
fi
if [[ $publish == true ]]; then
  printf 'Requesting production publication after signing and release environment approvals.\n'
fi
jq -n --arg build "$run" --arg resume "$resume" --arg publish "$publish" \
  '{build_run_id:$build,resume_run_id:$resume,publish_release:$publish}' |
  gh workflow run distribution.yml --repo "$repo" --ref main --json
