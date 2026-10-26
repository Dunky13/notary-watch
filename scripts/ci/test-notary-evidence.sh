#!/bin/bash
# Synthetic Apple provider: receipt binding, evidence mismatch, locks, safe export.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-evidence-tests.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/bin" "$work/state"
export TEST_EVIDENCE_ROOT="$work" PATH="$work/bin:$PATH" NOTARY_KEYCHAIN_PROFILE=fixture
export BUILD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa BUILD_RUN_ID=123 RELEASE_VERSION=9.8.7 RELEASE_BUILD=42 RELEASE_ARCHITECTURE=universal
unset NOTARY_KEY_FILE
archive="$work/state/Notary-Watch-App-9.8.7-build.42-123-universal.zip"
printf 'fixture signed archive\n' > "$archive"
export TEST_EVIDENCE_NAME TEST_EVIDENCE_DIGEST
TEST_EVIDENCE_NAME=$(basename "$archive")
TEST_EVIDENCE_DIGEST=$(shasum -a 256 "$archive" | awk '{print $1}')
cat > "$work/bin/xcrun" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ $1 == notarytool ]] || exit 91
printf 'PRIVATE-CLIENT-OUTPUT\n' >&2
case $2 in
  submit)
    printf 'upload\n' >> "$TEST_EVIDENCE_ROOT/uploads"
    printf '{"id":"12345678-1234-1234-1234-123456789abc","secret":"PRIVATE-CLIENT-OUTPUT"}\n'
    ;;
  wait)
    printf 'wait\n' >> "$TEST_EVIDENCE_ROOT/waits"
    if [[ ${TEST_WAIT_MODE:-normal} == transport ]]; then printf 'Error Domain=NSURLErrorDomain Code=-1005 "The network connection was lost."\n' >&2; exit 1; fi
    if [[ ${TEST_WAIT_MODE:-normal} == malformed ]]; then printf 'broken'; exit 1; fi
    printf '{"id":"%s","status":"%s","secret":"PRIVATE-CLIENT-OUTPUT"}\n' "${TEST_WAIT_ID:-12345678-1234-1234-1234-123456789abc}" "${TEST_WAIT_STATUS:-Accepted}"
    if [[ ${TEST_WAIT_MODE:-normal} == accepted-transport ]]; then printf 'The request timed out.\n' >&2; exit 1; fi
    [[ ${TEST_WAIT_STATUS:-Accepted} != 'In Progress' ]] || exit 124
    ;;
  log)
    path=${!#}
    [[ ${TEST_LOG_MODE:-normal} != missing ]] || exit 1
    [[ ${TEST_LOG_MODE:-normal} != no-output ]] || exit 0
    [[ ${TEST_LOG_MODE:-normal} != malformed ]] || { printf 'broken' > "$path"; exit 0; }
    if [[ ${TEST_LOG_MODE:-normal} == transport ]]; then printf 'Error Domain=NSURLErrorDomain Code=-1001 "The request timed out."\n' >&2; exit 1; fi
    if [[ ${TEST_LOG_MODE:-normal} == unauthorized ]]; then printf 'HTTP 401: Unauthorized. The request timed out.\n' >&2; exit 1; fi
    jq -n --arg id "${TEST_LOG_ID:-12345678-1234-1234-1234-123456789abc}" \
      --arg name "${TEST_LOG_NAME:-$TEST_EVIDENCE_NAME}" --arg digest "${TEST_LOG_DIGEST:-$TEST_EVIDENCE_DIGEST}" --arg severity "${TEST_LOG_SEVERITY:-warning}" \
      '{jobId:$id,status:"Accepted",archiveFilename:$name,sha256:$digest,issues:[{severity:$severity,message:"fixture warning"}],secret:"PRIVATE-CLIENT-OUTPUT"}' > "$path"
    ;;
  *) exit 92 ;;
esac
STUB
chmod +x "$work/bin/xcrun"
fail() { printf 'Notary evidence regression failed: %s\n' "$*" >&2; exit 1; }
expect_failure() { if ("$@") > "$work/failure.log" 2>&1; then fail 'Unexpected successful evidence gate.'; fi; }
submit() { "$root/scripts/notarize-stage.sh" submit app "$archive" "$work/state"; }
wait_for() { "$root/scripts/notarize-stage.sh" wait app "$archive" "$work/state"; }
expect_disposition() {
  jq -e --arg reason "$1" --argjson retry "$2" '.reason == $reason and .retryable == $retry' "$work/state/app.recovery.json" >/dev/null || fail "Wrong recovery disposition: $1/$2"
}
submit > /dev/null
jq -e '.schema == 2 and .commit == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .build == "42" and .ci_run_id == "123" and .architecture == "universal" and .id != null and (has("secret") | not)' "$work/state/app.submission.json" >/dev/null || fail 'Receipt lost provenance or included raw fields.'
submit > /dev/null
[[ $(wc -l < "$work/uploads" | tr -d ' ') == 1 ]] || fail 'Receipt caused a duplicate upload.'
expect_disposition upload_returned_uuid true
mkdir "$work/state/app.lock"
expect_failure submit
rmdir "$work/state/app.lock"
[[ $(wc -l < "$work/uploads" | tr -d ' ') == 1 ]] || fail 'Concurrent receipt uploaded again.'
RELEASE_BUILD=43 expect_failure submit
BUILD_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb expect_failure submit
wait_for > /dev/null
expect_disposition matching_accepted_log false
submit > /dev/null
expect_disposition existing_uuid false
wait_for > /dev/null
jq -e '.issues[0].message == "fixture warning" and (has("secret") | not)' "$work/state/app.log.json" >/dev/null || fail 'Warning disappeared or raw diagnostic field leaked.'
TEST_LOG_DIGEST=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff expect_failure wait_for
expect_disposition wait_started false
TEST_WAIT_MODE=accepted-transport TEST_LOG_DIGEST=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff expect_failure wait_for
expect_disposition wait_started false
TEST_LOG_NAME=Other-Product.zip expect_failure wait_for
TEST_LOG_ID=00000000-0000-0000-0000-000000000000 expect_failure wait_for
TEST_WAIT_ID=00000000-0000-0000-0000-000000000000 expect_failure wait_for
expect_disposition wait_started false
TEST_LOG_MODE=missing expect_failure wait_for
expect_disposition wait_started false
TEST_LOG_MODE=transport expect_failure wait_for
expect_disposition log_transport true
TEST_LOG_MODE=unauthorized expect_failure wait_for
expect_disposition wait_started false
TEST_WAIT_MODE=transport expect_failure wait_for
expect_disposition wait_transport true
TEST_WAIT_MODE=malformed expect_failure wait_for
expect_disposition wait_started false
TEST_WAIT_STATUS='In Progress' expect_failure wait_for
expect_disposition apple_pending true
# Resume exactly the same UUID after the pending response. No submit or new
# archive is needed, and the retained wait count records repeated observation.
attempts=$(jq -r '.wait_attempts' "$work/state/app.recovery.json")
wait_for > /dev/null
expect_disposition matching_accepted_log false
jq -e --argjson before "$attempts" '.wait_attempts == ($before + 1)' "$work/state/app.recovery.json" >/dev/null || fail 'Same-UUID continuation lost its wait count.'
[[ $(wc -l < "$work/uploads" | tr -d ' ') == 1 ]] || fail 'Pending continuation uploaded again.'
TEST_LOG_MODE=no-output expect_failure wait_for
[[ ! -e $work/state/app.log.json ]] || fail 'A missing new log reused stale evidence.'
TEST_LOG_SEVERITY=error expect_failure wait_for
TEST_LOG_SEVERITY=unexpected expect_failure wait_for
TEST_LOG_MODE=malformed expect_failure wait_for
wait_for > /dev/null
jq -n --arg digest "$TEST_EVIDENCE_DIGEST" \
  '{schema:2,commit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",run_id:"123",version:"9.8.7",build_number:"42",architecture:"universal",original_archive_sha256:$digest,secret:"PRIVATE-CLIENT-OUTPUT"}' > "$work/state/origin.json"
printf 'PRIVATE-CLIENT-OUTPUT\n' > "$work/state/raw.stderr"
printf 'PRIVATE-CLIENT-OUTPUT\n' > "$work/state/signing.p8"
"$root/scripts/checkpoint-macos.sh" "$work/state" "$work/safe" > /dev/null
[[ -f $work/safe/$TEST_EVIDENCE_NAME && -f $work/safe/app.submission.json && -f $work/safe/app.log.json && -f $work/safe/app.intent.json ]] || fail 'Safe checkpoint lost required recovery files.'
[[ -f $work/safe/app.recovery.json ]] || fail 'Safe checkpoint lost its bound recovery disposition.'
[[ ! -e $work/safe/private && ! -e $work/safe/raw.stderr && ! -e $work/safe/signing.p8 ]] || fail 'Private files entered checkpoint.'
if rg -q 'PRIVATE-CLIENT-OUTPUT' "$work/safe"; then fail 'Raw fields entered safe checkpoint.'; fi
expect_failure "$root/scripts/checkpoint-macos.sh" "$work/state" "$work/safe"
cp "$work/state/app.recovery.json" "$work/recovery-original.json"
jq '.commit = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$work/recovery-original.json" > "$work/state/app.recovery.json"
expect_failure "$root/scripts/checkpoint-macos.sh" "$work/state" "$work/unbound-disposition"
jq '.id = "00000000-0000-0000-0000-000000000000"' "$work/recovery-original.json" > "$work/state/app.recovery.json"
expect_failure "$root/scripts/checkpoint-macos.sh" "$work/state" "$work/foreign-uuid-disposition"
jq '.retryable = true' "$work/recovery-original.json" > "$work/state/app.recovery.json"
expect_failure "$root/scripts/checkpoint-macos.sh" "$work/state" "$work/forged-retry-disposition"
cp "$work/recovery-original.json" "$work/state/app.recovery.json"
# Exercise the fixed repository event hook in an isolated copy of the trusted
# script. Intent custody failure must stop before the provider sees an upload;
# receipt custody happens synchronously under the same stage lock after UUID.
mkdir -p "$work/hook-root/scripts/lib" "$work/hook-root/scripts/ci"
cp "$root/scripts/notarize-stage.sh" "$work/hook-root/scripts/"
cp "$root/scripts/lib/macos.sh" "$work/hook-root/scripts/lib/"
export TEST_REAL_ROOT="$root"
cat > "$work/hook-root/scripts/ci/persist-notary-event.sh" <<'HOOK'
#!/bin/bash
set -euo pipefail
state=$1 stage=$2 event=$3
printf '%s\n' "$event" >> "$state/events"
if [[ ${TEST_EVENT_FAILURE:-} == "$event" ]]; then exit 77; fi
"$TEST_REAL_ROOT/scripts/checkpoint-macos.sh" "$state" "$state/../$(basename "$state")-$event-${GITHUB_RUN_ID:-local}" "$stage" > /dev/null
HOOK
chmod +x "$work/hook-root/scripts/ci/persist-notary-event.sh"
for fixture in intent-failure receipt-failure complete; do
  mkdir "$work/$fixture"
  cp "$archive" "$work/$fixture/$TEST_EVIDENCE_NAME"
  cp "$work/state/origin.json" "$work/$fixture/origin.json"
done
uploads=$(wc -l < "$work/uploads" | tr -d ' ')
NW_DURABLE_EVENTS=true TEST_EVENT_FAILURE=intent expect_failure "$work/hook-root/scripts/notarize-stage.sh" submit app "$work/intent-failure/$TEST_EVIDENCE_NAME" "$work/intent-failure"
[[ $(wc -l < "$work/uploads" | tr -d ' ') == "$uploads" ]] || fail 'Upload proceeded without durable intent.'
NW_DURABLE_EVENTS=true TEST_EVENT_FAILURE=receipt expect_failure "$work/hook-root/scripts/notarize-stage.sh" submit app "$work/receipt-failure/$TEST_EVIDENCE_NAME" "$work/receipt-failure"
[[ -f $work/receipt-failure-intent-local/app.intent.json && -f $work/receipt-failure/app.submission.json ]] || fail 'Failed receipt custody lost its pre-upload reservation or local UUID.'
[[ $(cat "$work/receipt-failure/events") == $'intent\nreceipt' ]] || fail 'Receipt was not persisted immediately after intent/upload.'
NW_DURABLE_EVENTS=true GITHUB_RUN_ID=900 GITHUB_RUN_ATTEMPT=1 "$work/hook-root/scripts/notarize-stage.sh" submit app "$work/complete/$TEST_EVIDENCE_NAME" "$work/complete" > /dev/null
jq -e '.id != null and .retryable == true and .reason == "upload_returned_uuid" and .execution_run_id == "900" and .execution_attempt == "1"' "$work/complete-receipt-900/app.recovery.json" >/dev/null || fail 'Durable receipt was not bound and resumable.'
[[ ! -e $work/complete-receipt-900/app.lock ]] || fail 'Inline checkpoint exported its active lock.'
uploads=$(wc -l < "$work/uploads" | tr -d ' ')
NW_DURABLE_EVENTS=true GITHUB_RUN_ID=901 GITHUB_RUN_ATTEMPT=1 "$work/hook-root/scripts/notarize-stage.sh" submit app "$work/complete/$TEST_EVIDENCE_NAME" "$work/complete" > /dev/null
jq -e '.retryable == true and .execution_run_id == "901" and .reason == "upload_returned_uuid"' "$work/complete-receipt-901/app.recovery.json" >/dev/null || fail 'Known pending UUID was not persisted for the new execution.'
jq '.retryable = false | .outcome = "rejected" | .reason = "apple_rejected" | .operation = "wait"' "$work/complete/app.recovery.json" > "$work/rejected-recovery.json"
cp "$work/rejected-recovery.json" "$work/complete/app.recovery.json"
NW_DURABLE_EVENTS=true GITHUB_RUN_ID=902 GITHUB_RUN_ATTEMPT=1 "$work/hook-root/scripts/notarize-stage.sh" submit app "$work/complete/$TEST_EVIDENCE_NAME" "$work/complete" > /dev/null
jq -e '.retryable == false and .execution_run_id == "902" and .reason == "existing_uuid"' "$work/complete-receipt-902/app.recovery.json" >/dev/null || fail 'Known terminal UUID was incorrectly made retryable.'
[[ $(wc -l < "$work/uploads" | tr -d ' ') == "$uploads" ]] || fail 'Existing UUID custody repeated an upload.'
expect_failure "$root/scripts/checkpoint-macos.sh" "$work/state" "$work/invalid-active" app
mkdir "$work/state/app.lock" "$work/state/installer.lock"
expect_failure "$root/scripts/checkpoint-macos.sh" "$work/state" "$work/concurrent-active" app
rmdir "$work/state/app.lock" "$work/state/installer.lock"
jq '.sha256 = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' "$work/state/app.submission.json" > "$work/changed-receipt.json"
cp "$work/state/app.submission.json" "$work/receipt-original.json"
cp "$work/changed-receipt.json" "$work/state/app.submission.json"
expect_failure "$root/scripts/checkpoint-macos.sh" "$work/state" "$work/mismatched-receipt"
cp "$work/receipt-original.json" "$work/state/app.submission.json"
mv "$archive" "$archive.real"
ln -s "$archive.real" "$archive"
expect_failure "$root/scripts/checkpoint-macos.sh" "$work/state" "$work/unsafe-symlink"
[[ ! -e $work/unsafe-symlink ]] || fail 'Failed checkpoint left promotable output.'
# An initialized origin survives a credential setup failure without signing or
# submission; resuming it validates exactly the same metadata again.
mkdir "$work/input"
cp "$archive.real" "$work/input/Notary-Watch-App-9.8.7-universal-development.zip"
jq -n --arg digest "$TEST_EVIDENCE_DIGEST" \
  '{schema:1,commit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",run_id:"123",version:"9.8.7",build_number:"42",architecture:"universal",archive:"Notary-Watch-App-9.8.7-universal-development.zip",archive_sha256:$digest}' > "$work/input/build-metadata.json"
env -u APPLE_SIGNING_IDENTITY -u APPLE_TEAM_ID "$root/scripts/release-macos.sh" initialize "$work/input" "$work/initialized" "$work/output" > /dev/null
env -u APPLE_SIGNING_IDENTITY -u APPLE_TEAM_ID "$root/scripts/release-macos.sh" initialize "$work/input" "$work/initialized" "$work/output" > /dev/null
"$root/scripts/checkpoint-macos.sh" "$work/initialized" "$work/initial-checkpoint" > /dev/null
[[ -f $work/initial-checkpoint/origin.json ]] || fail 'Credential-free initialization did not retain its origin.'
BUILD_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb expect_failure "$root/scripts/release-macos.sh" initialize "$work/input" "$work/initialized" "$work/output"
printf 'Notarization evidence, provenance, concurrency, safe checkpoints, and initialization regressions passed.\n'
