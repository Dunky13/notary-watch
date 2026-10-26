#!/bin/bash
# Real resolver/controller contracts with an offline GitHub runner-loss witness.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-unstarted-tests.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/repository/scripts/ci" "$work/repository/scripts/lib"
cp "$root/scripts/ci/verify-unstarted.sh" "$root/scripts/ci/resolve-build.sh" "$root/scripts/ci/continue-release.sh" "$work/repository/scripts/ci/"
cp "$root/scripts/lib/macos.sh" "$root/scripts/lib/unstarted-jobs.jq" "$root/scripts/lib/retirement.jq" "$work/repository/scripts/lib/"
export TEST_UNSTARTED_ROOT="$work" PATH="$work/bin:$PATH" GH_REPO=fixture/repo
export GITHUB_REPOSITORY=fixture/repo BUILD_RUN_ID=100 GITHUB_RUN_ID=300 GITHUB_RUN_NUMBER=30 GITHUB_RUN_ATTEMPT=1 GITHUB_EVENT_NAME=workflow_dispatch RESUME_RUN_ID=200 GITHUB_OUTPUT="$work/output"
cat > "$work/bin/gh" <<'STUB'
#!/bin/bash
set -euo pipefail
if [[ $1 == workflow ]]; then cat > "$TEST_UNSTARTED_ROOT/dispatched.json"; exit 0; fi
[[ $1 == api ]] || exit 90
case $* in
  *'/workflows/distribution.yml/runs?'*) cat "$TEST_UNSTARTED_ROOT/runs.json" ;;
  *'/releases?'*) cat "$TEST_UNSTARTED_ROOT/releases.json" ;;
  *'/runs/100/artifacts?'*) printf '{"id":101,"name":"Notary-Watch-unsigned-100-a1","expired":false}\n' ;;
  *'/attempts/1/jobs?'*)
    [[ ${TEST_JOB_API_FAILURE:-false} != true ]] || exit 33
    if [[ $* == *'/runs/150/'* ]]; then jq -c '.[]' "$TEST_UNSTARTED_ROOT/older-jobs.json";
    else jq -c '.[]' "$TEST_UNSTARTED_ROOT/jobs.json"; fi ;;
  *'/runs/100')
    jq -n '{id:100,path:".github/workflows/ci.yml",head_branch:"main",event:"push",status:"completed",conclusion:"success",run_attempt:1,run_number:7,head_sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repository:{full_name:"fixture/repo"},head_repository:{full_name:"fixture/repo"}}' ;;
  *'/actions/runs/'*)
    [[ $* =~ /actions/runs/([0-9]+)$ ]] || exit 91
    id=${BASH_REMATCH[1]}
    jq -se --argjson id "$id" '[.[] | select(.id == $id)][0]' "$TEST_UNSTARTED_ROOT/runs.json" > "$TEST_UNSTARTED_ROOT/selected.json"
    jq -s '.[0] + .[1]' "$TEST_UNSTARTED_ROOT/run-template.json" "$TEST_UNSTARTED_ROOT/selected.json" ;;
  *) exit 92 ;;
esac
STUB
chmod +x "$work/bin/gh"
reset_fixture() {
  rm -f "$work/dispatched.json"
  : > "$work/output"
  : > "$work/releases.json"
  jq -n '{id:200,run_number:2,status:"completed",conclusion:"failure",display_title:"Notary Watch distribution from CI 100"}' > "$work/runs.json"
  jq -n '{path:".github/workflows/distribution.yml",head_branch:"main",event:"workflow_run",run_attempt:1,repository:{full_name:"fixture/repo"},head_repository:{full_name:"fixture/repo"}}' > "$work/run-template.json"
  jq -n '[
    {name:"Verify original successful main CI artifact",status:"completed",conclusion:"cancelled",runner_id:0,runner_name:"",steps:[]},
    {name:"Sign app and notarize named app ZIP and installer DMG",status:"completed",conclusion:"skipped",runner_id:0,runner_name:"",steps:[]},
    {name:"Signed installer acceptance",status:"completed",conclusion:"skipped",runner_id:0,runner_name:"",steps:[]},
    {name:"Publish verified stable macOS release",status:"completed",conclusion:"skipped",runner_id:0,runner_name:"",steps:[]}
  ]' > "$work/jobs.json"
  cp "$work/jobs.json" "$work/older-jobs.json"
}
change() { jq "$2" "$1" > "$work/changed.json"; mv "$work/changed.json" "$1"; }
fail() { printf 'Unstarted recovery regression failed: %s\n' "$*" >&2; exit 1; }
resolve() { : > "$work/output"; "$work/repository/scripts/ci/resolve-build.sh" > "$work/resolve.log" 2>&1; }
controller() { "$work/repository/scripts/ci/continue-release.sh" > "$work/controller.log" 2>&1; }
expect_hold() {
  if resolve; then fail 'Resolver discarded missing state without complete no-execution proof.'; fi
  [[ ! -s $work/output ]] || fail 'Rejected recovery exposed a partial handoff.'
  controller > /dev/null 2>&1 || true
  [[ ! -e $work/dispatched.json ]] || fail 'Controller restarted a potentially executed candidate.'
}
expect_dispatch() {
  local expected_bootstrap=${1:-true}
  resolve || { cat "$work/resolve.log" >&2; fail 'Proven unstarted candidate was not recoverable.'; }
  grep -Fx "bootstrap_resume=$expected_bootstrap" "$work/output" > /dev/null || fail 'Recovery discarded a state checkpoint or lacked a proven initial state.'
  grep -Fx 'artifact_id=101' "$work/output" > /dev/null || fail 'Recovery changed the original CI artifact.'
  controller || { cat "$work/controller.log" >&2; fail 'Controller did not resume a proven unstarted candidate.'; }
  jq -e '.build_run_id == "100" and .resume_run_id == "200"' "$work/dispatched.json" > /dev/null || fail 'Controller changed candidate lineage.'
}
reset_fixture
expect_dispatch
for filter in \
  '.[1].steps = [{name:"Submit",status:"completed",conclusion:"failure"}]' \
  '.[1].runner_name = "assigned-runner"' \
  '.[1] |= del(.runner_id)' \
  '. += [.[1]]'; do
  reset_fixture
  change "$work/jobs.json" "$filter"
  expect_hold
done
for filter in \
  '.[0].steps = [{name:"Read source",status:"completed",conclusion:"success"}] | .[0].conclusion = "success" | .[0].runner_id = 42' \
  '.[1].conclusion = "failure"'; do
  reset_fixture
  change "$work/jobs.json" "$filter"
  expect_dispatch
done
reset_fixture
change "$work/jobs.json" '.[0].conclusion = "success" | .[0].runner_id = 42 | .[0].runner_name = "source-runner" | .[0].steps = [{name:"Read source",conclusion:"success",status:"completed"}]
  | .[1].conclusion = "failure" | .[1].runner_id = 43 | .[1].runner_name = "signing-runner"
  | .[1].steps = (["Prepare a signed universal app without rebuilding it","Submit descriptive product-version-build-universal app ZIP","Require app acceptance, fetch its log, staple, and prepare the DMG","Submit descriptive product-version-build-universal installer DMG","Require DMG acceptance, staple, verify Finder copy, and finalize checksums"] | map({name:.,status:"completed",conclusion:"skipped"}))
  | .[1].steps += [{name:"Initialize candidate",status:"completed",conclusion:"success"},{name:"Save initial custody",status:"completed",conclusion:"failure"}]'
cp "$work/jobs.json" "$work/presigning-jobs.json"
expect_dispatch
reset_fixture
cp "$work/presigning-jobs.json" "$work/jobs.json"
jq -n '{tag_name:"notary-state-ci-100",target_commitish:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",draft:true,prerelease:true,assets:[]}' > "$work/releases.json"
expect_dispatch
reset_fixture
cp "$work/presigning-jobs.json" "$work/jobs.json"
jq -n '{tag_name:"notary-state-ci-100",target_commitish:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",draft:true,prerelease:true,assets:[{name:"source.tar"},{name:"source.tar.sha256"},{name:"state-r200-s00.tar"},{name:"state-r200-s00.tar.sha256"}]}' > "$work/releases.json"
expect_dispatch false
grep -Fx 'recovery_slot=00' "$work/output" > /dev/null || fail 'Slot00 recovery could discard an inherited submission UUID.'
reset_fixture
cp "$work/presigning-jobs.json" "$work/jobs.json"
change "$work/jobs.json" '.[1].steps[0].conclusion = "failure"'
expect_hold
for filter in '.path = ".github/workflows/other.yml"' '.head_repository.full_name = "foreign/repo"' '.run_attempt = 2'; do
  reset_fixture
  change "$work/run-template.json" "$filter"
  expect_hold
done
reset_fixture
change "$work/runs.json" '.conclusion = "cancelled"'
expect_hold
reset_fixture
printf '{"id":150,"run_number":1,"status":"completed","conclusion":"failure","display_title":"Notary Watch distribution from CI 100"}\n' >> "$work/runs.json"
expect_dispatch
rm "$work/dispatched.json"
change "$work/older-jobs.json" '.[1].runner_id = 42 | .[1].conclusion = "failure" | .[1].steps = [{name:"Submit",conclusion:"failure"}]'
expect_hold
reset_fixture
jq -n '{tag_name:"notary-state-ci-100",target_commitish:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",draft:true,prerelease:true,assets:[{name:"state-r150-s05.tar"}]}' > "$work/releases.json"
expect_hold
reset_fixture
for id in $(seq 201 211); do
  jq -nc --argjson id "$id" '{id:$id,run_number:($id - 200),status:"completed",conclusion:"failure",display_title:"Notary Watch distribution from CI 100"}' >> "$work/runs.json"
done
# Keep 200 as latest so dispatch metadata stays fixed; twelve candidate runs
# still exhaust the controller budget before it may start another execution.
change "$work/runs.json" 'if .id == 200 then .run_number = 20 else . end'
controller > /dev/null 2>&1 || true
[[ ! -e $work/dispatched.json ]] || fail 'Unstarted retries bypassed the twelve-attempt budget.'
reset_fixture
export TEST_JOB_API_FAILURE=true
expect_hold
unset TEST_JOB_API_FAILURE
printf 'Unstarted candidate recovery, complete lineage, no-upload proof and bounded continuation witnesses passed.\n'
