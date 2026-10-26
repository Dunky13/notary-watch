#!/bin/bash
# Offline discovery fixtures: no GitHub writes, Apple requests, or credentials.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-dispatch-tests.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin"
export PATH="$work/bin:$PATH" TEST_DISPATCH="$work"
export GITHUB_REPOSITORY=fixture/repo GITHUB_RUN_ID=300 BUILD_RUN_ID=100 GITHUB_OUTPUT="$work/output"
unset RESUME_RUN_ID
cat > "$work/bin/gh" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ $1 == api ]] || exit 90
case $* in
  *'/workflows/distribution.yml/runs?'*)
    [[ ${TEST_LIST_FAIL:-false} != true ]] || exit 33
    # Current run always appears; it must not prevent the first dispatch.
    printf '{"id":300,"display_title":"Notary Watch distribution from CI 100","status":"in_progress"}\n'
    # A later queued duplicate must not prevent this first attempt from starting.
    printf '{"id":400,"display_title":"Notary Watch distribution from CI 100","status":"queued"}\n'
    if [[ ${TEST_PRIOR:-false} == true ]]; then
      printf '{"id":200,"display_title":"Notary Watch distribution from CI %s","status":"completed"}\n' "${TEST_PRIOR_BUILD:-100}"
    fi
    if [[ ${TEST_NEWER_PRIOR:-false} == true ]]; then
      printf '{"id":250,"display_title":"Notary Watch distribution from CI 100","status":"%s"}\n' "${TEST_RECOVERY_STATUS:-completed}"
    fi ;;
  *'/runs/100/artifacts?'*)
    printf '{"id":101,"expired":false,"name":"Notary-Watch-unsigned-100-a1"}\n' ;;
  *'/runs/200/artifacts?'*|*'/runs/250/artifacts?'*)
    if [[ ${TEST_NO_CHECKPOINT:-false} != true ]]; then
      run=200
      [[ $* != *'/runs/250/'* ]] || run=250
      printf '{"id":%s,"expired":false,"name":"Notary-Watch-state-100-r%s-a1-s10"}\n' "$((run + 1))" "$run"
    fi ;;
  *'/runs/200'*|*'/runs/250'*)
    jq -n --arg status "${TEST_RECOVERY_STATUS:-completed}" --arg build "${TEST_RECOVERY_BUILD:-100}" \
      '{head_branch:"main",path:".github/workflows/distribution.yml",event:"workflow_dispatch",status:$status,display_title:("Notary Watch distribution from CI " + $build),repository:{full_name:"fixture/repo"},head_repository:{full_name:"fixture/repo"}}' ;;
  *'/runs/100'*)
    printf '{"head_branch":"main","path":".github/workflows/ci.yml","event":"push","status":"completed","conclusion":"success","head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","run_number":7,"repository":{"full_name":"fixture/repo"},"head_repository":{"full_name":"fixture/repo"}}\n' ;;
  *) exit 91 ;;
esac
STUB
chmod +x "$work/bin/gh"
fail() { printf 'dispatch test failed: %s\n' "$*" >&2; exit 1; }
resolve() { : > "$GITHUB_OUTPUT"; "$root/scripts/ci/resolve-build.sh" > "$work/result.log" 2>&1; }
expect_failure() { if (resolve); then fail "$1"; fi; }
resolve
grep -Fx 'artifact_id=101' "$GITHUB_OUTPUT" >/dev/null || fail 'First dispatch did not bind the successful CI artifact.'
export TEST_PRIOR=true
expect_failure 'A fresh dispatch repeated a previously attempted candidate.'
[[ ! -s $GITHUB_OUTPUT ]] || fail 'A duplicate fresh dispatch exposed release outputs before reconciliation.'
export TEST_PRIOR_BUILD=999
resolve
unset TEST_PRIOR_BUILD
export RESUME_RUN_ID=200
resolve
grep -Fx 'recovery_artifact_id=201' "$GITHUB_OUTPUT" >/dev/null || fail 'Explicit completed recovery did not restore its pinned checkpoint.'
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
export TEST_LIST_FAIL=true
expect_failure 'Failed run discovery was treated as an unused candidate.'
printf 'Production dispatch duplicate and recovery witnesses passed.\n'
