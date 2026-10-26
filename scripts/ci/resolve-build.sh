#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/../lib/macos.sh"
[[ ${BUILD_RUN_ID:-} =~ ^[1-9][0-9]*$ ]] || nw_fail 'Choose an original CI run ID.'
[[ -n ${GITHUB_REPOSITORY:-} && -n ${GITHUB_OUTPUT:-} && ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]*$ && ${GITHUB_RUN_NUMBER:-} =~ ^[1-9][0-9]*$ ]] || nw_fail 'GitHub workflow context is missing.'
[[ ${GITHUB_RUN_ATTEMPT:-1} == 1 ]] || nw_fail 'Workflow reruns may lose newer submission receipts. Start a new manual dispatch and recover from the latest completed distribution run.'
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
trigger_sha=
case ${GITHUB_EVENT_NAME:-workflow_dispatch} in
  workflow_dispatch) ;;
  workflow_run)
    [[ -f ${GITHUB_EVENT_PATH:-} ]] || nw_fail 'The automatic CI completion event is missing.'
    jq -e --arg repo "$GITHUB_REPOSITORY" --arg run "$BUILD_RUN_ID" \
      '.action == "completed" and .repository.full_name == $repo and
       .workflow_run.name == "CI" and (.workflow_run.id | tostring) == $run and
       .workflow_run.event == "push" and .workflow_run.head_branch == "main" and
       .workflow_run.head_repository.full_name == $repo and
       .workflow_run.status == "completed" and .workflow_run.conclusion == "success" and
       (.workflow_run.head_sha | test("^[a-f0-9]{40}$"))' \
      "$GITHUB_EVENT_PATH" >/dev/null || nw_fail 'Automatic distribution requires the exact successful main-push CI event from this repository.'
    trigger_sha=$(jq -er '.workflow_run.head_sha' "$GITHUB_EVENT_PATH")
    ;;
  *) nw_fail 'Only a manual dispatch or successful CI completion may start distribution.' ;;
esac
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
[[ -z $trigger_sha || $trigger_sha == "$sha" ]] || nw_fail 'The automatic completion event differs from the pinned CI source commit.'
number=$(jq -er '.run_number' "$work/run.json")
build_attempt=$(jq -er '.run_attempt | select(type == "number" and . >= 1 and . == floor)' "$work/run.json") || nw_fail 'Original CI attempt is missing.'
# A new workflow run otherwise starts with no local receipt and could upload the
# same candidate again. Even an early failed run requires explicit reconciliation.
gh api --paginate "repos/$GITHUB_REPOSITORY/actions/workflows/distribution.yml/runs?per_page=100" \
  --jq '.workflow_runs[]' | jq -s --arg build "$BUILD_RUN_ID" --argjson current "$GITHUB_RUN_NUMBER" \
  '[.[] | select(.display_title == ("Notary Watch distribution from CI " + $build))]
   | if all(.[]; (.run_number | type == "number" and . >= 1 and . == floor)) then
       [.[] | select(.run_number < $current)]
     else error("Distribution run ordering evidence is missing") end' > "$work/prior-runs.json"
if [[ -z ${RESUME_RUN_ID:-} ]]; then
  [[ $(jq length "$work/prior-runs.json") == 0 ]] || nw_fail 'This candidate already has a distribution run. Reconcile it and set resume_run_id; refusing a fresh upload.'
else
  [[ $RESUME_RUN_ID =~ ^[1-9][0-9]*$ && $RESUME_RUN_ID != "$GITHUB_RUN_ID" ]] || nw_fail 'Invalid recovery run ID.'
  latest=$(jq -er 'max_by(.run_number) | .id // empty' "$work/prior-runs.json") || nw_fail 'No earlier distribution run exists for this recovery candidate.'
  [[ $RESUME_RUN_ID == "$latest" ]] || nw_fail 'Recovery must use the latest earlier distribution attempt; an older checkpoint could lose submission IDs.'
fi
gh api --paginate "repos/$GITHUB_REPOSITORY/actions/runs/$BUILD_RUN_ID/artifacts?per_page=100" \
  --jq '.artifacts[]' | jq -s --arg run "$BUILD_RUN_ID" \
  '[.[] | select(.expired == false and (.name | test("^Notary-Watch-unsigned-" + $run + "-a[1-9][0-9]*$")))
    | . + {attempt:(.name | capture("-a(?<attempt>[1-9][0-9]*)$").attempt | tonumber)}]
   | sort_by(.attempt) | group_by(.attempt) | last // []' > "$work/artifact.json"
jq -e --argjson attempt "$build_attempt" 'length == 1 and .[0].attempt == $attempt' "$work/artifact.json" >/dev/null || nw_fail 'The successful CI attempt must have exactly one retained universal installer artifact.'
artifact=$(jq -er '.[0].id' "$work/artifact.json")
recovery=
if [[ -n ${RESUME_RUN_ID:-} ]]; then
  validate_run "$RESUME_RUN_ID" '.github/workflows/distribution.yml'
  jq -e --arg build "$BUILD_RUN_ID" \
    '(.event == "workflow_dispatch" or .event == "workflow_run") and .status == "completed" and .run_attempt == 1 and .display_title == ("Notary Watch distribution from CI " + $build)' \
    "$work/run.json" >/dev/null || nw_fail 'Recovery must come from the completed automatic or manual distribution run for this candidate.'
  gh api --paginate "repos/$GITHUB_REPOSITORY/actions/runs/$RESUME_RUN_ID/attempts/1/jobs?per_page=100" \
    --jq '.jobs[]' | jq -s '[.[] | select(.name == "Sign app and notarize named app ZIP and installer DMG")]' > "$work/signing-job.json"
  jq -e 'length == 1 and .[0].status == "completed" and (.[0].steps | type == "array")' "$work/signing-job.json" >/dev/null || nw_fail 'Completed recovery signing-job evidence is missing or ambiguous.'
  # IDs are opaque. Bind the required checkpoint to the last attempted stage,
  # including failed/cancelled uploads that may already have a submission UUID.
  slots=(05 10 20 30 40)
  names=(
    'Prepare a signed universal app without rebuilding it'
    'Submit descriptive product-version-build-universal app ZIP'
    'Require app acceptance, fetch its log, staple, and prepare the DMG'
    'Submit descriptive product-version-build-universal installer DMG'
    'Require DMG acceptance, staple, verify Finder copy, and finalize checksums'
  )
  required_slot=00
  for index in "${!slots[@]}"; do
    jq -e --arg name "${names[$index]}" \
      '[.[0].steps[] | select(.name == $name)] | length == 1 and .[0].status == "completed" and (.[0].conclusion | type == "string")' \
      "$work/signing-job.json" >/dev/null || nw_fail 'Recovery stage execution evidence is missing or ambiguous.'
    conclusion=$(jq -er --arg name "${names[$index]}" '.[0].steps[] | select(.name == $name) | .conclusion' "$work/signing-job.json")
    [[ $conclusion == skipped ]] || required_slot=${slots[$index]}
  done
  gh api --paginate "repos/$GITHUB_REPOSITORY/actions/runs/$RESUME_RUN_ID/artifacts?per_page=100" \
    --jq '.artifacts[]' | jq -s --arg build "$BUILD_RUN_ID" --arg run "$RESUME_RUN_ID" \
    '[.[] | select(.expired == false and (.name | test("^Notary-Watch-state-" + $build + "-r" + $run + "-a[1-9][0-9]*-s(00|05|10|20|30|40)$")))
      | . + (.name | capture("-a(?<attempt>[1-9][0-9]*)-s(?<slot>00|05|10|20|30|40)$") | {attempt:(.attempt | tonumber),slot:(.slot | tonumber)})]
     | sort_by(.slot)' > "$work/recovery.json"
  jq -e --argjson slot "$((10#$required_slot))" \
    'length > 0 and all(.[]; .attempt == 1) and .[-1].slot == $slot and ([.[] | select(.slot == $slot)] | length == 1)' \
    "$work/recovery.json" >/dev/null || nw_fail 'The latest attempted stage has no unique retained checkpoint. Reconcile its submission before recovery; refusing an older snapshot.'
  recovery=$(jq -er '.[-1].id' "$work/recovery.json")
fi
# Expose the pinned handoff only after every source and recovery gate passes.
printf 'sha=%s\nrun_number=%s\nartifact_id=%s\n' "$sha" "$number" "$artifact" >> "$GITHUB_OUTPUT"
if [[ -n $recovery ]]; then printf 'recovery_artifact_id=%s\n' "$recovery" >> "$GITHUB_OUTPUT"; fi
