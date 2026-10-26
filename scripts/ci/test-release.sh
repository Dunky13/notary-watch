#!/bin/bash
# Offline regression witnesses for uploads, recovery, provenance, and owned Keychain cleanup.
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
work=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-tests.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin" "$work/state" "$work/runner"
export TEST_ROOT="$work" PATH="$work/bin:$PATH" NOTARY_KEYCHAIN_PROFILE=fixture
unset NOTARY_KEY_FILE
cat > "$work/bin/xcrun" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ $1 == notarytool ]] || exit 93
case $2 in
  submit)
    printf '%s\n' "$(basename "$3")" >> "$TEST_ROOT/uploads"
    if [[ ${TEST_SUBMIT_MODE:-normal} == unknown ]]; then printf '{"message":"connection lost"}\n'; exit 7; fi
    printf '{"id":"12345678-1234-1234-1234-123456789abc"}\n'
    [[ ${TEST_SUBMIT_MODE:-normal} != with-id-error ]] || exit 9
    ;;
  wait)
    printf '{"status":"%s"}\n' "${TEST_WAIT_STATUS:-Accepted}"
    [[ ${TEST_WAIT_STATUS:-Accepted} != 'In Progress' ]] || exit 124
    ;;
  log)
    path=${!#}
    printf '{"jobId":"12345678-1234-1234-1234-123456789abc","status":"%s","issues":null}\n' "${TEST_WAIT_STATUS:-Accepted}" > "$path"
    ;;
  *) exit 94 ;;
esac
STUB
cat > "$work/bin/sleep" <<'STUB'
#!/bin/bash
exit 0
STUB
cat > "$work/bin/hdiutil" <<'STUB'
#!/bin/bash
set -euo pipefail
count=0
[[ ! -f $TEST_ROOT/images ]] || count=$(cat "$TEST_ROOT/images")
count=$((count + 1)); printf '%s\n' "$count" > "$TEST_ROOT/images"
target=${!#}
: > "$target"
case ${TEST_IMAGE_MODE:-success} in
  transient) if [[ $count -lt 3 ]]; then printf 'hdiutil: create failed - Resource busy\n' >&2; exit 47; fi ;;
  busy) printf 'hdiutil: create failed - Resource busy\n' >&2; exit 47 ;;
  mixed) printf 'hdiutil: create failed - Resource busy\npermission denied\n' >&2; exit 48 ;;
esac
STUB
cat > "$work/bin/gh" <<'STUB'
#!/bin/bash
set -euo pipefail
if [[ $* == *'/artifacts?'* ]]; then
  if [[ $* == *'/runs/200/'* ]]; then
    printf '{"id":201,"expired":false,"name":"Notary-Watch-state-100-r200-a1-s10"}\n'
  else
    printf '{"id":101,"expired":false,"name":"Notary-Watch-unsigned-100-a1"}\n'
  fi
elif [[ $* == *'/runs/200'* ]]; then
  printf '{"head_branch":"main","path":".github/workflows/distribution.yml","event":"workflow_dispatch","repository":{"full_name":"fixture/repo"},"head_repository":{"full_name":"fixture/repo"}}\n'
else
  printf '{"head_branch":"%s","path":".github/workflows/ci.yml","event":"%s","status":"completed","conclusion":"success","head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","run_number":7,"repository":{"full_name":"fixture/repo"},"head_repository":{"full_name":"fixture/repo"}}\n' "${TEST_SOURCE_BRANCH:-main}" "${TEST_SOURCE_EVENT:-push}"
fi
STUB
cat > "$work/bin/security" <<'STUB'
#!/bin/bash
set -euo pipefail
operation=$1; shift
case $operation in
  list-keychains)
    if [[ $* == *'-s'* ]]; then
      shift 3
      : > "$TEST_ROOT/search-list"
      for item in "$@"; do printf '    "%s"\n' "$item" >> "$TEST_ROOT/search-list"; done
    else cat "$TEST_ROOT/search-list"; fi
    ;;
  create-keychain) : > "${!#}" ;;
  delete-keychain) rm -f -- "$1" ;;
  find-identity) printf '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Fixture (AB12CD34E5)"\n     1 valid identities found\n' ;;
  import) [[ ${TEST_IMPORT_FAIL:-false} != true ]] || exit 33 ;;
  unlock-keychain|set-keychain-settings|set-key-partition-list) ;;
  *) exit 95 ;;
esac
STUB
chmod +x "$work/bin/"*
fail() { printf 'release test failed: %s\n' "$*" >&2; exit 1; }
expect_failure() { if ("$@") > "$work/failure.log" 2>&1; then fail "Unexpected success: $*"; fi; }
archive="$work/Notary-Watch-App-9.8.7-universal.zip"
printf 'immutable fixture\n' > "$archive"
submit() { "$root/scripts/notarize-stage.sh" submit app "$archive" "$1"; }
wait_for() { "$root/scripts/notarize-stage.sh" wait app "$archive" "$1"; }
submit "$work/state" > "$work/submit.log"
submit "$work/state" >> "$work/submit.log"
[[ $(wc -l < "$work/uploads" | tr -d ' ') == 1 ]] || fail 'A recorded submission was uploaded twice.'
grep -Fx 'Notary-Watch-App-9.8.7-universal.zip' "$work/uploads" >/dev/null || fail 'Submission name lost its product/version/stage.'
wait_for "$work/state" > "$work/wait.log"
[[ -s $work/state/app.log.json ]] || fail 'Successful notarization log was discarded.'
export TEST_WAIT_STATUS='In Progress'
expect_failure wait_for "$work/state"
[[ -s $work/state/app.submission.json ]] || fail 'A timed-out submission lost its ID.'
export TEST_WAIT_STATUS=Invalid
expect_failure wait_for "$work/state"
grep 'Invalid' "$work/state/app.log.json" >/dev/null || fail 'Rejection log was not fetched.'
unset TEST_WAIT_STATUS
export APPLE_NOTARY_TIMEOUT=31m
expect_failure wait_for "$work/state"
unset APPLE_NOTARY_TIMEOUT
printf 'changed\n' >> "$archive"
expect_failure submit "$work/state"
printf 'immutable fixture\n' > "$archive"
export TEST_SUBMIT_MODE=unknown
expect_failure submit "$work/ambiguous"
[[ -f $work/ambiguous/app.intent.json ]] || fail 'Unknown upload result lost its intent.'
count=$(wc -l < "$work/uploads")
expect_failure submit "$work/ambiguous"
[[ $(wc -l < "$work/uploads") == "$count" ]] || fail 'An ambiguous upload was repeated.'
export TEST_SUBMIT_MODE=with-id-error
expect_failure submit "$work/with-id"
[[ -f $work/with-id/app.submission.json ]] || fail 'An ID returned with an error was lost.'
unset TEST_SUBMIT_MODE
submit "$work/with-id" > /dev/null
# shellcheck source=scripts/lib/macos.sh
source "$root/scripts/lib/macos.sh"
cat > "$work/bin/lipo" <<'STUB'
#!/bin/bash
[[ $1 == -archs ]] || exit 86
printf '%s\n' "${TEST_ARCHITECTURES:-arm64 x86_64}"
STUB
chmod +x "$work/bin/lipo"
nw_require_universal "$archive"
[[ $(nw_arch "$archive") == universal ]] || fail 'Universal architecture detection failed.'
export TEST_ARCHITECTURES=arm64
expect_failure nw_require_universal "$archive"
[[ $(nw_arch "$archive") == arm64 ]] || fail 'Apple Silicon architecture detection failed.'
export TEST_ARCHITECTURES=x86_64
expect_failure nw_require_universal "$archive"
[[ $(nw_arch "$archive") == x86_64 ]] || fail 'Intel architecture detection failed.'
unset TEST_ARCHITECTURES
export TEST_IMAGE_MODE=transient
nw_create_dmg "$work" "$work/test.dmg" Test > "$work/image.log" 2>&1
[[ $(cat "$work/images") == 3 ]] || fail 'Resource busy retry was not bounded at three attempts.'
printf '0\n' > "$work/images"
export TEST_IMAGE_MODE=busy
expect_failure nw_create_dmg "$work" "$work/test.dmg" Test
[[ $(cat "$work/images") == 3 ]] || fail 'Persistent image failure exceeded its retry budget.'
printf '0\n' > "$work/images"
export TEST_IMAGE_MODE=mixed
expect_failure nw_create_dmg "$work" "$work/test.dmg" Test
[[ $(cat "$work/images") == 1 ]] || fail 'Mixed stderr was incorrectly treated as a transient Resource busy failure.'
export GITHUB_REPOSITORY=fixture/repo GITHUB_RUN_ID=300 BUILD_RUN_ID=100 GITHUB_OUTPUT="$work/output" RESUME_RUN_ID=200
"$root/scripts/ci/resolve-build.sh"
grep -Fx 'artifact_id=101' "$work/output" >/dev/null || fail 'Original artifact was not pinned.'
grep -Fx 'recovery_artifact_id=201' "$work/output" >/dev/null || fail 'Recovery artifact was not pinned.'
export TEST_SOURCE_BRANCH=feature
expect_failure "$root/scripts/ci/resolve-build.sh"
unset TEST_SOURCE_BRANCH
export TEST_SOURCE_EVENT=pull_request
expect_failure "$root/scripts/ci/resolve-build.sh"
unset TEST_SOURCE_EVENT
GITHUB_ACTIONS=false RUNNER_ENVIRONMENT=github-hosted expect_failure "$root/scripts/with-apple-signing.sh" /usr/bin/true
printf '    "/fixture/login.keychain-db"\n' > "$work/search-list"
cp "$work/search-list" "$work/search-original"
export GITHUB_ACTIONS=true RUNNER_ENVIRONMENT=github-hosted RUNNER_TEMP="$work/runner"
export APPLE_TEAM_ID=AB12CD34E5 APPLE_SIGNING_IDENTITY='Developer ID Application: Fixture (AB12CD34E5)'
export APPLE_DEVELOPER_ID_P12_BASE64=Zml4dHVyZQ== APPLE_DEVELOPER_ID_P12_PASSWORD=fixture APPLE_NOTARY_KEY_P8=fixture
export APPLE_NOTARY_KEY_ID=FIXTURE123 APPLE_NOTARY_ISSUER_ID=12345678-1234-1234-1234-123456789abc
cat > "$work/child.sh" <<'CHILD'
#!/bin/bash
set -euo pipefail
[[ -z ${APPLE_DEVELOPER_ID_P12_BASE64:-} && -z ${APPLE_DEVELOPER_ID_P12_PASSWORD:-} && -z ${APPLE_NOTARY_KEY_P8:-} ]]
[[ -s $NOTARY_KEY_FILE && -n $APPLE_SIGNING_KEYCHAIN ]]
exit 12
CHILD
result=0
"$root/scripts/with-apple-signing.sh" bash "$work/child.sh" > "$work/wrapper.log" 2>&1 || result=$?
[[ $result == 12 ]] || { cat "$work/wrapper.log" >&2; fail 'Signing wrapper masked the child exit status or leaked raw credentials.'; }
cmp -s "$work/search-list" "$work/search-original" || fail 'Original Keychain list was not restored.'
[[ -z $(find "$work/runner" -mindepth 1 -print -quit) ]] || fail 'Temporary signing material survived failure.'
export TEST_IMPORT_FAIL=true
result=0
"$root/scripts/with-apple-signing.sh" /usr/bin/true > "$work/wrapper-import.log" 2>&1 || result=$?
[[ $result == 33 ]] || fail 'Certificate import failure was masked.'
cmp -s "$work/search-list" "$work/search-original" || fail 'Keychain list was not restored after import failure.'
[[ -z $(find "$work/runner" -mindepth 1 -print -quit) ]] || fail 'Signing material survived import failure.'
printf 'Release regressions passed: descriptive names, immutable recovery, bounded retries, trusted provenance, and Keychain cleanup.\n'
