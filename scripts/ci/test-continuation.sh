#!/bin/bash
# Offline controller witnesses. No real credentials, Apple calls or dispatches.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-continuation-tests.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/repo/scripts/lib" "$work/repo/scripts/ci"
cp "$root/scripts/ci/continue-release.sh" "$work/repo/scripts/ci/"
cp "$root/scripts/lib/macos.sh" "$work/repo/scripts/lib/"
export PATH="$work/bin:$PATH" TEST_CONTINUATION_ROOT="$work" GH_REPO=fixture/repo
cat > "$work/bin/gh" <<'STUB'
#!/bin/bash
set -euo pipefail
if [[ $1 == workflow ]]; then
  [[ $* == 'workflow run distribution.yml --repo fixture/repo --ref main --json' ]] || exit 91
  cat > "$TEST_CONTINUATION_ROOT/dispatch.json"
  exit 0
fi
[[ $1 == api ]] || exit 92
case $* in
  *'/workflows/distribution.yml/runs?'*) cat "$TEST_CONTINUATION_ROOT/runs.json" ;;
  *'/releases?'*) cat "$TEST_CONTINUATION_ROOT/releases.json" ;;
  *'/attempts/1/jobs?'*) cat "$TEST_CONTINUATION_ROOT/jobs.json" ;;
  *'/actions/runs/200') cat "$TEST_CONTINUATION_ROOT/run.json" ;;
  *'/actions/runs/100') cat "$TEST_CONTINUATION_ROOT/build.json" ;;
  *) printf 'Unexpected mocked GitHub endpoint: %s\n' "$*" >&2; exit 93 ;;
esac
STUB
cat > "$work/repo/scripts/ci/durable-state.sh" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ $BUILD_SHA == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa && $BUILD_RUN_ID == 100 ]] || exit 94
printf '%s\n' "$*" >> "$TEST_CONTINUATION_ROOT/restores"
case $1 in
  restore)
    [[ $# == 4 && $2 == 200 ]] || exit 95
    [[ $3 == "$(cat "$TEST_CONTINUATION_ROOT/expected-slot")" ]] || exit 96
    mkdir "$4"
    cp "$TEST_CONTINUATION_ROOT/recovery.json" "$4/$(jq -r '.stage' "$TEST_CONTINUATION_ROOT/recovery.json").recovery.json"
    ;;
  restore-final)
    [[ $# == 2 ]] || exit 97
    [[ -f $TEST_CONTINUATION_ROOT/final-valid ]] || exit 98
    mkdir "$2"
    ;;
  *) exit 99 ;;
esac
STUB
chmod +x "$work/bin/gh" "$work/repo/scripts/ci/durable-state.sh"
fail() { printf 'Continuation regression failed: %s\n' "$*" >&2; exit 1; }
reset_fixture() {
  rm -f "$work/dispatch.json" "$work/restores" "$work/final-valid"
  printf '20\n' > "$work/expected-slot"
  jq -n '{id:200,run_number:2,status:"completed",conclusion:"failure",display_title:"Notary Watch distribution from CI 100"}' > "$work/runs.json"
  jq -n '{id:200,path:".github/workflows/distribution.yml",head_branch:"main",run_attempt:1,event:"workflow_run",status:"completed",repository:{full_name:"fixture/repo"},head_repository:{full_name:"fixture/repo"}}' > "$work/run.json"
  jq -n '{id:100,path:".github/workflows/ci.yml",head_branch:"main",event:"push",status:"completed",conclusion:"success",head_sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repository:{full_name:"fixture/repo"},head_repository:{full_name:"fixture/repo"}}' > "$work/build.json"
  jq -n '{tag_name:"notary-state-ci-100",target_commitish:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",draft:true,prerelease:true,assets:[{name:"state-r200-s20.tar"},{name:"state-r200-s20.tar.sha256"}]}' > "$work/releases.json"
  jq -n '{name:"Sign app and notarize named app ZIP and installer DMG",status:"completed",steps:[
    {name:"Prepare a signed universal app without rebuilding it",conclusion:"success"},
    {name:"Submit descriptive product-version-build-universal app ZIP",conclusion:"success"},
    {name:"Require app acceptance, fetch its log, staple, and prepare the DMG",conclusion:"failure"},
    {name:"Submit descriptive product-version-build-universal installer DMG",conclusion:"skipped"},
    {name:"Require DMG acceptance, staple, verify Finder copy, and finalize checksums",conclusion:"skipped"}]}' > "$work/jobs.json"
  jq -n '{schema:2,stage:"app",archive:"Notary-Watch-App-1.0.0-build.7-100-universal.zip",sha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",commit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",version:"1.0.0",build:"7",architecture:"universal",ci_run_id:"100",id:"12345678-1234-1234-1234-123456789abc",operation:"wait",outcome:"pending",reason:"apple_pending",retryable:true,wait_attempts:1,execution_run_id:"200",execution_attempt:"1"}' > "$work/recovery.json"
}
change() {
  local file=$1 filter=$2
  jq "$filter" "$file" > "$work/changed.json"
  mv "$work/changed.json" "$file"
}
run_controller() { "$work/repo/scripts/ci/continue-release.sh" > "$work/controller.log" 2>&1; }
expect_skip() {
  run_controller || { cat "$work/controller.log" >&2; fail 'Expected a safe controller skip.'; }
  [[ ! -e $work/dispatch.json ]] || fail 'Ineligible candidate was dispatched.'
}
expect_failure() {
  if run_controller; then fail 'Unsafe controller input succeeded.'; fi
  [[ ! -e $work/dispatch.json ]] || fail 'Unsafe controller input dispatched a workflow.'
}
expect_alert() {
  expect_failure
  grep -q '^::error::' "$work/controller.log" || fail 'Blocked candidate did not emit an operator alert.'
}
expect_dispatch() {
  run_controller || { cat "$work/controller.log" >&2; fail 'Eligible candidate did not continue.'; }
  [[ -f $work/dispatch.json ]] || fail 'Eligible candidate was not dispatched.'
  jq -e 'keys == ["build_run_id","resume_run_id"] and .build_run_id == "100" and .resume_run_id == "200"' "$work/dispatch.json" >/dev/null || fail 'Continuation changed the original candidate/run binding.'
}
reset_fixture
expect_dispatch
[[ $(wc -l < "$work/restores" | tr -d ' ') == 1 ]] || fail 'Controller restored a candidate more than once.'
for reason in wait_transport log_transport upload_returned_uuid; do
  reset_fixture
  change "$work/recovery.json" ".reason = \"$reason\""
  expect_dispatch
done
reset_fixture
# No stage-end checkpoint after runner loss: use the bound inline UUID snapshot.
change "$work/releases.json" '.assets |= map(.name |= sub("s20";"s12"))'
printf '12\n' > "$work/expected-slot"
change "$work/recovery.json" '.operation = "submit" | .outcome = "submitted" | .reason = "upload_returned_uuid"'
expect_dispatch
reset_fixture
# An intent records a possibly completed upload and never authorizes a new one.
change "$work/releases.json" '.assets |= map(.name |= sub("s20";"s11"))'
printf '11\n' > "$work/expected-slot"
change "$work/recovery.json" '.id = null | .outcome = "ambiguous" | .reason = "reconcile_upload" | .retryable = false'
expect_alert
for filter in '.retryable = false' '.reason = "apple_rejected"' '.execution_run_id = "199"' '.execution_attempt = "2"' '.stage = "installer"' '.id = null'; do
  reset_fixture
  change "$work/recovery.json" "$filter"
  expect_alert
done
reset_fixture
: > "$work/runs.json"
expect_skip
[[ ! -e $work/restores ]] || fail 'An empty candidate inventory loaded state.'
reset_fixture
# A newer active run for this candidate blocks recovery from the older failure.
cat >> "$work/runs.json" <<'RUN'
{"id":201,"run_number":3,"status":"in_progress","conclusion":null,"display_title":"Notary Watch distribution from CI 100"}
RUN
expect_skip
[[ ! -e $work/restores ]] || fail 'An active candidate restored older state.'
reset_fixture
# The eleventh attempt may still queue the twelfth observation.
jq -n 'range(1;12) | {id:(189 + .),run_number:.,status:"completed",conclusion:"failure",display_title:"Notary Watch distribution from CI 100"}' > "$work/runs.json"
expect_dispatch
reset_fixture
# Twelve total attempts are a hard automatic ceiling, even with valid state.
jq -n 'range(1;13) | {id:(188 + .),run_number:.,status:"completed",conclusion:"failure",display_title:"Notary Watch distribution from CI 100"}' > "$work/runs.json"
expect_alert
[[ ! -e $work/restores ]] || fail 'Exhausted candidate loaded credentials/state.'
for filter in '.head_branch = "feature"' '.head_repository.full_name = "foreign/repo"' '.run_attempt = 2' '.path = ".github/workflows/other.yml"'; do
  reset_fixture
  change "$work/run.json" "$filter"
  expect_failure
done
for filter in '.event = "pull_request"' '.head_repository.full_name = "foreign/repo"' '.conclusion = "failure"'; do
  reset_fixture
  change "$work/build.json" "$filter"
  expect_failure
done
reset_fixture
change "$work/releases.json" '.target_commitish = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
expect_failure
reset_fixture
# Final custody delegates exact byte/manifest validation before dispatch and
# needs no repeat signing, notarization, or submission-status interpretation.
change "$work/releases.json" '.assets = [{name:"final.tar"},{name:"final.tar.sha256"}]'
: > "$work/final-valid"
expect_dispatch
grep -q '^restore-final ' "$work/restores" || fail 'Final bytes were not restored before dispatch.'
reset_fixture
change "$work/releases.json" '.assets = [{name:"final.tar"},{name:"final.tar.sha256"}]'
expect_failure
printf 'Automatic continuation regressions passed: exact candidate, bounded recovery, terminal holds, active-run exclusion, and final custody.\n'
