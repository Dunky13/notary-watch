#!/bin/bash
# A finite controller. GitHub schedules future runs; no sleeping worker or human
# approval bot holds credentials while Apple processes an existing submission.
set -euo pipefail
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/../lib/macos.sh"
[[ ${GH_REPO:-} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || nw_fail 'Repository is required.'
work=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-continuation.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
gh api --paginate "repos/$GH_REPO/actions/workflows/distribution.yml/runs?per_page=100" --jq '.workflow_runs[]' |
  jq -s '[.[] | select(.display_title | test("^Notary Watch distribution from CI [1-9][0-9]*$"))]
    | group_by(.display_title) | map({attempts:length,latest:max_by(.run_number),runs:sort_by(.run_number)})
    | sort_by(.latest.run_number) | reverse | .[] | @base64' -r > "$work/candidates"
gh api --paginate "repos/$GH_REPO/releases?per_page=100" --jq '.[]' | jq -s '.' > "$work/releases.json"
blocked=false
queue_resume() {
  jq -n --arg build "$1" --arg resume "$2" '{build_run_id:$build,resume_run_id:$resume}' |
    gh workflow run distribution.yml --repo "$GH_REPO" --ref main --json
  printf 'Queued continuation of original CI %s from distribution %s.\n' "$1" "$2"
}
while IFS= read -r candidate; do
  printf '%s' "$candidate" | base64 --decode > "$work/candidate.json"
  attempts=$(jq -er '.attempts' "$work/candidate.json")
  run=$(jq -er '.latest.id' "$work/candidate.json")
  [[ $run =~ ^[1-9][0-9]*$ ]] || nw_fail 'Invalid continuation run identity.'
  jq -e '.latest.status == "completed" and (.latest.conclusion == "failure" or .latest.conclusion == "timed_out")' "$work/candidate.json" >/dev/null || continue
  build=$(jq -er '.latest.display_title | capture("CI (?<id>[1-9][0-9]*)$").id' "$work/candidate.json")
  gh api "repos/$GH_REPO/actions/runs/$run" > "$work/run.json"
  jq -e --arg repo "$GH_REPO" ' .path == ".github/workflows/distribution.yml" and .head_branch == "main" and .run_attempt == 1
    and .repository.full_name == $repo and .head_repository.full_name == $repo
    and (.event == "workflow_run" or .event == "workflow_dispatch") and .status == "completed"' "$work/run.json" >/dev/null || nw_fail 'Unsafe continuation workflow provenance.'
  gh api "repos/$GH_REPO/actions/runs/$build" > "$work/build.json"
  jq -e --arg repo "$GH_REPO" '.path == ".github/workflows/ci.yml" and .head_branch == "main" and .event == "push"
    and .status == "completed" and .conclusion == "success" and .repository.full_name == $repo and .head_repository.full_name == $repo
    and (.head_sha | test("^[a-f0-9]{40}$"))' "$work/build.json" >/dev/null || nw_fail 'Unsafe original build provenance.'
  BUILD_SHA=$(jq -er '.head_sha' "$work/build.json")
  BUILD_RUN_ID=$build
  export BUILD_SHA BUILD_RUN_ID
  jq --arg tag "notary-state-ci-$build" '[.[] | select(.tag_name == $tag)]' "$work/releases.json" > "$work/drafts.json"
  if [[ $(jq length "$work/drafts.json") == 0 ]]; then
    jq '.runs' "$work/candidate.json" > "$work/lineage.json"
    if "$NW_ROOT/scripts/ci/verify-unstarted.sh" "$work/lineage.json" "$GH_REPO" "$build" > "$work/unstarted-proof.log" 2>&1; then
      if ((attempts >= 12)); then printf '::error::Candidate exhausted twelve automatic attempts: %s. Operator investigation required.\n' "$run"; blocked=true; continue; fi
      queue_resume "$build" "$run"
      exit 0
    fi
    # No empty-state retry is permitted for legacy or ambiguous executions.
    printf 'Candidate CI %s has no durable custody or complete no-execution proof; held.\n' "$build"
    continue
  fi
  jq -e --arg sha "$BUILD_SHA" 'length == 1 and .[0].draft == true and .[0].prerelease == true and .[0].target_commitish == $sha' "$work/drafts.json" >/dev/null || nw_fail 'Invalid durable continuation custody.'
  retired=$(jq '[.[0].assets[] | select(.name == "retired.json")] | length' "$work/drafts.json")
  if [[ $retired != 0 ]]; then
    retirement_id=$(jq -er '[.[0].assets[] | select(.name == "retired.json")] |
      if length == 1 and (.[0].id | type == "number" and . > 0) then .[0].id else error("Ambiguous retirement asset") end' "$work/drafts.json") || nw_fail 'Retirement asset is ambiguous.'
    gh api -H 'Accept: application/octet-stream' "repos/$GH_REPO/releases/assets/$retirement_id" > "$work/retired.json"
    jq -e --arg sha "$BUILD_SHA" --arg run "$BUILD_RUN_ID" --arg execution "$run" \
      -f "$NW_ROOT/scripts/lib/retirement.jq" "$work/retired.json" >/dev/null || nw_fail 'Retirement does not bind this source and latest failed execution.'
    printf 'Candidate CI %s is explicitly retired at distribution %s. No continuation.\n' "$build" "$run"
    continue
  fi
  if ((attempts >= 12)); then printf '::error::Candidate exhausted twelve automatic attempts: %s. Operator investigation required.\n' "$run"; blocked=true; continue; fi
  if jq -e '.[0].assets | any(.[]; .name == "final.tar" or .name == "final.tar.sha256")' "$work/drafts.json" >/dev/null; then
    "$NW_ROOT/scripts/ci/durable-state.sh" restore-final "$work/final-$run"
  else
    gh api --paginate "repos/$GH_REPO/actions/runs/$run/attempts/1/jobs?per_page=100" --jq '.jobs[]' |
      jq -s '[.[] | select(.name == "Sign app and notarize named app ZIP and installer DMG")]' > "$work/jobs.json"
    jq -e 'length == 1 and .[0].status == "completed"' "$work/jobs.json" >/dev/null || continue
    slot=00
    names=(
      'Prepare a signed universal app without rebuilding it'
      'Submit descriptive product-version-build-universal app ZIP'
      'Require app acceptance, fetch its log, staple, and prepare the DMG'
      'Submit descriptive product-version-build-universal installer DMG'
      'Require DMG acceptance, staple, verify Finder copy, and finalize checksums'
    )
    slots=(05 10 20 30 40)
    for index in "${!slots[@]}"; do
      conclusion=$(jq -er --arg name "${names[$index]}" '[.[0].steps[] | select(.name == $name)] | select(length == 1) | .[0].conclusion' "$work/jobs.json") || nw_fail 'Ambiguous continuation stage evidence.'
      [[ $conclusion == skipped ]] || slot=${slots[$index]}
    done
    case $slot in
      10|20) stage=app; fallback=(12 11) ;;
      30|40) stage=installer; fallback=(32 31) ;;
      *) continue ;;
    esac
    selected=$slot
    for possible in "$slot" "${fallback[@]}"; do
      if jq -e --arg name "state-r$run-s$possible.tar" '.[0].assets | any(.[]; .name == $name or .name == ($name + ".sha256"))' "$work/drafts.json" >/dev/null; then selected=$possible; break; fi
    done
    "$NW_ROOT/scripts/ci/durable-state.sh" restore "$run" "$selected" "$work/state-$run"
    record="$work/state-$run/$stage.recovery.json"
    if [[ ! -f $record ]]; then printf '::error::Distribution %s has no bound recovery disposition. Reconciliation required.\n' "$run"; blocked=true; continue; fi
    if ! jq -e --arg run "$run" --arg stage "$stage" '.retryable == true and .stage == $stage and .execution_run_id == $run and .execution_attempt == "1"
      and (.id | type == "string" and test("^[A-Fa-f0-9]{8}(-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}$"))
      and (.reason == "apple_pending" or .reason == "wait_transport" or .reason == "log_transport" or .reason == "upload_returned_uuid")' "$record" >/dev/null; then
      printf '::error::Distribution %s requires operator investigation of terminal or unbound evidence. No automatic upload.\n' "$run"
      blocked=true
      continue
    fi
  fi
  # Distribution serializes this original build and independently revalidates
  # latest-run ordering; duplicate scheduled/completion events cannot reupload.
  queue_resume "$build" "$run"
  exit 0
done < "$work/candidates"
printf 'No eligible continuation.\n'
[[ $blocked == false ]]
