#!/bin/bash
# Offline discovery fixtures: no GitHub writes, Apple requests, or credentials.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-dispatch-tests.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin"
export PATH="$work/bin:$PATH" TEST_DISPATCH="$work"
export GITHUB_REPOSITORY=fixture/repo GITHUB_RUN_ID=300 GITHUB_RUN_NUMBER=3 BUILD_RUN_ID=100 GITHUB_OUTPUT="$work/output" GITHUB_EVENT_NAME=workflow_dispatch GITHUB_RUN_ATTEMPT=1
unset RESUME_RUN_ID
cat > "$work/bin/gh" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ $1 == api ]] || exit 90
case $* in
  *'/workflows/distribution.yml/runs?'*)
    [[ ${TEST_LIST_FAIL:-false} != true ]] || exit 33
    # Current run always appears; it must not prevent the first dispatch.
    printf '{"id":%s,"run_number":3,"display_title":"Notary Watch distribution from CI 100","status":"in_progress"}\n' "$GITHUB_RUN_ID"
    # A later queued duplicate must not prevent this first attempt from starting.
    printf '{"id":400,"run_number":4,"display_title":"Notary Watch distribution from CI 100","status":"queued"}\n'
    if [[ ${TEST_IGNORED_PRIOR:-false} == true ]]; then
      printf '{"id":150,"run_number":1,"display_title":"Ignored Notary Watch distribution from CI 100","status":"completed","conclusion":"skipped"}\n'
    fi
    if [[ ${TEST_PRIOR:-false} == true ]]; then
      printf '{"id":%s,"run_number":1,"display_title":"Notary Watch distribution from CI %s","status":"completed"}\n' "${TEST_PRIOR_ID:-200}" "${TEST_PRIOR_BUILD:-100}"
    fi
    if [[ ${TEST_NEWER_PRIOR:-false} == true ]]; then
      printf '{"id":%s,"run_number":2,"display_title":"Notary Watch distribution from CI 100","status":"%s"}\n' "${TEST_NEWER_PRIOR_ID:-250}" "${TEST_RECOVERY_STATUS:-completed}"
    fi ;;
  *'/runs/100/artifacts?'*)
    printf '{"id":101,"expired":false,"name":"Notary-Watch-unsigned-100-a1"}\n'
    if [[ ${TEST_BUILD_ATTEMPT:-1} == 2 || ${TEST_BUILD_ARTIFACT_NEWER:-false} == true ]]; then
      printf '{"id":99,"expired":false,"name":"Notary-Watch-unsigned-100-a2"}\n'
    fi ;;
  *'/attempts/1/jobs?'*)
    [[ ${TEST_NO_JOBS:-false} != true ]] || exit 0
    jq -n --arg slot "${TEST_STAGE_SLOT:-10}" --arg conclusion "${TEST_STAGE_CONCLUSION:-success}" \
      '{name:"Sign app and notarize named app ZIP and installer DMG",status:"completed",steps:([
        {slot:5,name:"Prepare a signed universal app without rebuilding it"},
        {slot:10,name:"Submit descriptive product-version-build-universal app ZIP"},
        {slot:20,name:"Require app acceptance, fetch its log, staple, and prepare the DMG"},
        {slot:30,name:"Submit descriptive product-version-build-universal installer DMG"},
        {slot:40,name:"Require DMG acceptance, staple, verify Finder copy, and finalize checksums"}
      ] | map(. + {status:"completed",conclusion:(if .slot < ($slot | tonumber) then "success" elif .slot == ($slot | tonumber) then $conclusion else "skipped" end)}))}' ;;
  *'/runs/200/artifacts?'*|*'/runs/250/artifacts?'*|*'/runs/900/artifacts?'*|*'/runs/50/artifacts?'*)
    if [[ ${TEST_NO_CHECKPOINT:-false} != true ]]; then
      run=200
      [[ $* != *'/runs/250/'* ]] || run=250
      [[ $* != *'/runs/900/'* ]] || run=900
      [[ $* != *'/runs/50/'* ]] || run=50
      # Artifact IDs do not encode stage order: the initial snapshot has a
      # greater ID than later stages, matching the hosted failure witness.
      printf '{"id":999,"expired":false,"name":"Notary-Watch-state-100-r%s-a1-s00"}\n' "$run"
      slot=${TEST_STAGE_SLOT:-10}
      if [[ $slot != 00 && ${TEST_LOST_STAGE:-false} != true ]]; then
        printf '{"id":%s,"expired":%s,"name":"Notary-Watch-state-100-r%s-a1-s%s"}\n' "$((run + 1))" "${TEST_EXPIRED_STAGE:-false}" "$run" "$slot"
        if [[ ${TEST_DUPLICATE_STAGE:-false} == true ]]; then
          printf '{"id":199,"expired":false,"name":"Notary-Watch-state-100-r%s-a1-s%s"}\n' "$run" "$slot"
        fi
      fi
    fi ;;
  *'/runs/200'*|*'/runs/250'*|*'/runs/900'*|*'/runs/50'*)
    jq -n --arg status "${TEST_RECOVERY_STATUS:-completed}" --arg build "${TEST_RECOVERY_BUILD:-100}" --arg event "${TEST_RECOVERY_EVENT:-workflow_dispatch}" --argjson attempt "${TEST_RECOVERY_ATTEMPT:-1}" \
      '{head_branch:"main",path:".github/workflows/distribution.yml",event:$event,status:$status,run_attempt:$attempt,display_title:("Notary Watch distribution from CI " + $build),repository:{full_name:"fixture/repo"},head_repository:{full_name:"fixture/repo"}}' ;;
  *'/runs/100'*)
    printf '{"head_branch":"main","path":".github/workflows/ci.yml","event":"push","status":"completed","conclusion":"success","head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","run_number":7,"run_attempt":%s,"repository":{"full_name":"fixture/repo"},"head_repository":{"full_name":"fixture/repo"}}\n' "${TEST_BUILD_ATTEMPT:-1}" ;;
  *) exit 91 ;;
esac
STUB
chmod +x "$work/bin/gh"
fail() { printf 'dispatch test failed: %s\n' "$*" >&2; exit 1; }
# The canonical title defines recovery lineage, so its eligibility must match
# the source gate rather than marking ignored completion events as attempts.
name_gate=$(awk '/^run-name: >-$/ { capture=1; next } capture && /format\(/ { exit } capture { print }' "$root/.github/workflows/distribution.yml" | tr -d '[:space:]')
name_gate=${name_gate#"\${{"}
name_gate=${name_gate%&&}
source_gate=$(awk '/^  source:$/ { source_job=1 } source_job && /^    if: >-$/ { capture=1; next } capture && /^    runs-on:/ { exit } capture { print }' "$root/.github/workflows/distribution.yml" | tr -d '[:space:]')
[[ -n $name_gate && $name_gate == "$source_gate" ]] || fail 'Canonical distribution title eligibility differs from the source gate.'
grep -F "format('Ignored Notary Watch distribution from CI {0}'," "$root/.github/workflows/distribution.yml" >/dev/null || fail 'Ineligible completions lack a distinct ignored title.'
resolve() { : > "$GITHUB_OUTPUT"; "$root/scripts/ci/resolve-build.sh" > "$work/result.log" 2>&1; }
expect_failure() {
  if (resolve); then fail "$1"; fi
  [[ ! -s $GITHUB_OUTPUT ]] || fail 'A failed source or recovery gate exposed a partial artifact handoff.'
}
resolve
grep -Fx 'artifact_id=101' "$GITHUB_OUTPUT" >/dev/null || fail 'First dispatch did not bind the successful CI artifact.'
export TEST_BUILD_ATTEMPT=2
resolve
grep -Fx 'artifact_id=99' "$GITHUB_OUTPUT" >/dev/null || fail 'A greater artifact ID overrode the successful CI attempt number.'
unset TEST_BUILD_ATTEMPT
export TEST_BUILD_ARTIFACT_NEWER=true
expect_failure 'CI artifact evidence differed from the recorded successful attempt.'
unset TEST_BUILD_ARTIFACT_NEWER
export GITHUB_EVENT_NAME=workflow_run GITHUB_EVENT_PATH="$work/event.json"
jq -n '{action:"completed",repository:{full_name:"fixture/repo"},workflow_run:{name:"CI",id:100,event:"push",head_branch:"main",head_repository:{full_name:"fixture/repo"},status:"completed",conclusion:"success",head_sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' > "$work/valid-event.json"
cp "$work/valid-event.json" "$GITHUB_EVENT_PATH"
resolve
grep -Fx 'artifact_id=101' "$GITHUB_OUTPUT" >/dev/null || fail 'Automatic successful main CI did not pin its original artifact.'
export TEST_IGNORED_PRIOR=true TEST_BUILD_ATTEMPT=2
jq '.workflow_run.run_attempt = 2' "$work/valid-event.json" > "$GITHUB_EVENT_PATH"
resolve
grep -Fx 'artifact_id=99' "$GITHUB_OUTPUT" >/dev/null || fail 'Ignored failed CI completion blocked successful rerun of the same CI ID.'
unset TEST_IGNORED_PRIOR TEST_BUILD_ATTEMPT
cp "$work/valid-event.json" "$GITHUB_EVENT_PATH"
for mutation in \
  '.action = "requested"' \
  '.repository.full_name = "attacker/repo"' \
  '.workflow_run.name = "Other"' \
  '.workflow_run.id = 999' \
  '.workflow_run.event = "pull_request"' \
  '.workflow_run.event = "workflow_dispatch"' \
  '.workflow_run.head_branch = "feature"' \
  '.workflow_run.head_repository.full_name = "attacker/repo"' \
  '.workflow_run.status = "in_progress"' \
  '.workflow_run.conclusion = "failure"' \
  '.workflow_run.head_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'; do
  jq "$mutation" "$work/valid-event.json" > "$GITHUB_EVENT_PATH"
  expect_failure "Automatic distribution accepted an unsafe completion event: $mutation"
done
export GITHUB_EVENT_PATH="$work/missing-event.json"
expect_failure 'Automatic distribution accepted missing event evidence.'
export GITHUB_EVENT_NAME=pull_request
expect_failure 'A pull request directly invoked the distribution resolver.'
export GITHUB_EVENT_NAME=workflow_dispatch
unset GITHUB_EVENT_PATH
export TEST_PRIOR=true
expect_failure 'A fresh dispatch repeated a previously attempted candidate.'
[[ ! -s $GITHUB_OUTPUT ]] || fail 'A duplicate fresh dispatch exposed release outputs before reconciliation.'
export TEST_PRIOR_BUILD=999
resolve
unset TEST_PRIOR_BUILD
export RESUME_RUN_ID=200
resolve
grep -Fx 'recovery_artifact_id=201' "$GITHUB_OUTPUT" >/dev/null || fail 'Explicit completed recovery did not restore its pinned checkpoint.'
export TEST_STAGE_SLOT=05 TEST_STAGE_CONCLUSION=failure
resolve
grep -Fx 'recovery_artifact_id=201' "$GITHUB_OUTPUT" >/dev/null || fail 'Initial s00 with greater ID overrode later failed prepare s05.'
export TEST_LOST_STAGE=true
expect_failure 'A missing attempted stage checkpoint fell back to initial state.'
unset TEST_LOST_STAGE
export TEST_STAGE_SLOT=30 TEST_STAGE_CONCLUSION=cancelled TEST_EXPIRED_STAGE=true
expect_failure 'Expired upload checkpoint fell back to a pre-upload snapshot.'
unset TEST_EXPIRED_STAGE
resolve
grep -Fx 'recovery_artifact_id=201' "$GITHUB_OUTPUT" >/dev/null || fail 'Cancelled upload did not require its later-stage snapshot.'
export TEST_DUPLICATE_STAGE=true
expect_failure 'Duplicate latest-stage checkpoint evidence was accepted.'
unset TEST_DUPLICATE_STAGE
export TEST_STAGE_SLOT=00
resolve
grep -Fx 'recovery_artifact_id=999' "$GITHUB_OUTPUT" >/dev/null || fail 'An unattempted signing flow could not recover its initial state.'
unset TEST_STAGE_SLOT TEST_STAGE_CONCLUSION
export TEST_NO_JOBS=true
expect_failure 'Missing job execution evidence selected a potentially stale snapshot.'
unset TEST_NO_JOBS
export TEST_RECOVERY_ATTEMPT=2
expect_failure 'A rerun recovery source bypassed first-attempt checkpoint binding.'
unset TEST_RECOVERY_ATTEMPT
export TEST_RECOVERY_EVENT=workflow_run
resolve
grep -Fx 'recovery_artifact_id=201' "$GITHUB_OUTPUT" >/dev/null || fail 'A completed automatic distribution could not be recovered manually.'
export TEST_RECOVERY_EVENT=push
expect_failure 'Recovery accepted an unrelated workflow event.'
unset TEST_RECOVERY_EVENT
export TEST_NEWER_PRIOR=true
expect_failure 'A stale completed checkpoint was accepted despite a newer distribution attempt.'
[[ ! -s $GITHUB_OUTPUT ]] || fail 'Stale recovery exposed outputs before its newest-attempt check.'
export RESUME_RUN_ID=250 TEST_RECOVERY_STATUS=in_progress
expect_failure 'An older checkpoint could bypass the newest pending attempt.'
unset TEST_RECOVERY_STATUS
export TEST_NO_CHECKPOINT=true
expect_failure 'A missing newest checkpoint fell back to an older attempt.'
unset TEST_NO_CHECKPOINT
resolve
grep -Fx 'recovery_artifact_id=251' "$GITHUB_OUTPUT" >/dev/null || fail 'Newest completed recovery did not restore its checkpoint.'
unset TEST_NEWER_PRIOR
export RESUME_RUN_ID=200
export GITHUB_RUN_ATTEMPT=2
expect_failure 'A rerun could discard its own earlier-attempt submission IDs.'
unset GITHUB_RUN_ATTEMPT
export TEST_RECOVERY_STATUS=in_progress
expect_failure 'An active run was used as a recovery checkpoint.'
unset TEST_RECOVERY_STATUS
export TEST_RECOVERY_BUILD=999
expect_failure 'Recovery from a different candidate was accepted.'
unset TEST_RECOVERY_BUILD
export TEST_NO_CHECKPOINT=true
expect_failure 'A prior attempt with no retained checkpoint was silently restarted.'
unset TEST_NO_CHECKPOINT
export RESUME_RUN_ID=300
expect_failure 'A run recovered from its own incomplete state.'
unset RESUME_RUN_ID
export TEST_PRIOR_ID=900
expect_failure 'An earlier workflow number with a greater opaque run ID was ignored.'
export RESUME_RUN_ID=900
resolve
grep -Fx 'recovery_artifact_id=901' "$GITHUB_OUTPUT" >/dev/null || fail 'An earlier run with a greater ID could not be recovered.'
export TEST_NEWER_PRIOR=true TEST_NEWER_PRIOR_ID=50 GITHUB_RUN_ID=1000
expect_failure 'Opaque run ID order overrode the newer workflow run number.'
[[ ! -s $GITHUB_OUTPUT ]] || fail 'Stale recovery exposed outputs before workflow-order validation.'
export RESUME_RUN_ID=50
resolve
grep -Fx 'recovery_artifact_id=51' "$GITHUB_OUTPUT" >/dev/null || fail 'Latest workflow number with a lower ID did not select its checkpoint.'
unset TEST_PRIOR_ID TEST_NEWER_PRIOR TEST_NEWER_PRIOR_ID RESUME_RUN_ID
export GITHUB_RUN_ID=300
unset GITHUB_RUN_NUMBER
expect_failure 'Run ordering proceeded without its workflow-scoped run number.'
export GITHUB_RUN_NUMBER=3
export TEST_LIST_FAIL=true
expect_failure 'Failed run discovery was treated as an unused candidate.'
printf 'Production dispatch duplicate and recovery witnesses passed.\n'
