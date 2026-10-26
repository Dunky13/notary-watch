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
printf '%s\n' "${DEVELOPER_DIR:-default}" >> "$TEST_EVIDENCE_ROOT/client-selection"
printf 'PRIVATE-CLIENT-OUTPUT\n' >&2
case $2 in
  submit)
    printf 'upload\n' >> "$TEST_EVIDENCE_ROOT/uploads"
    printf '{"id":"12345678-1234-1234-1234-123456789abc","secret":"PRIVATE-CLIENT-OUTPUT"}\n'
    ;;
  wait)
    printf 'wait\n' >> "$TEST_EVIDENCE_ROOT/waits"
    if [[ ${TEST_WAIT_MODE:-normal} == native-timeout ]]; then exit 124; fi
    if [[ ${TEST_WAIT_MODE:-normal} == transport ]]; then printf 'Error Domain=NSURLErrorDomain Code=-1005 "The network connection was lost."\n' >&2; exit 1; fi
    if [[ ${TEST_WAIT_MODE:-normal} == malformed ]]; then printf 'broken'; exit 1; fi
    if [[ ${TEST_WAIT_MODE:-normal} == unauthorized-empty ]]; then printf 'HTTP 403: Forbidden.\n' >&2; exit 124; fi
    printf '{"id":"%s","status":"%s","secret":"PRIVATE-CLIENT-OUTPUT"}\n' "${TEST_WAIT_ID:-12345678-1234-1234-1234-123456789abc}" "${TEST_WAIT_STATUS:-Accepted}"
    if [[ ${TEST_WAIT_MODE:-normal} == accepted-transport ]]; then printf 'The request timed out.\n' >&2; exit 1; fi
    [[ ${TEST_WAIT_STATUS:-Accepted} != 'In Progress' ]] || exit 124
    ;;
  info)
    [[ $3 == 12345678-1234-1234-1234-123456789abc ]] || exit 94
    printf 'info\n' >> "$TEST_EVIDENCE_ROOT/infos"
    printf '%s\n' "${DEVELOPER_DIR:-default}" >> "$TEST_EVIDENCE_ROOT/info-client-selection"
    case ${TEST_INFO_MODE:-normal} in
      malformed) printf 'broken'; exit 0 ;;
      empty) exit 0 ;;
      unauthorized) printf 'HTTP 401: Unauthorized. The request timed out.\n' >&2; exit 1 ;;
      transport) printf 'The network connection was lost.\n' >&2; exit 1 ;;
      contradictory-transport) printf '{"id":"foreign","status":"Accepted"}\n'; printf 'The network connection was lost.\n' >&2; exit 1 ;;
      bad-types) printf '{"id":42,"status":["Accepted"]}\n'; exit 0 ;;
      multiple) printf '{"id":"foreign","status":"Accepted"}\n{"id":"12345678-1234-1234-1234-123456789abc","status":"Accepted"}\n'; exit 0 ;;
      hang) /bin/sleep 60; exit 1 ;;
    esac
    if [[ ${TEST_INFO_MODE:-normal} == unauthorized-json ]]; then printf 'HTTP 401: Unauthorized.\n' >&2; fi
    jq -n --arg id "${TEST_INFO_ID-12345678-1234-1234-1234-123456789abc}" \
      --arg name "${TEST_INFO_NAME-$TEST_EVIDENCE_NAME}" --arg digest "${TEST_INFO_DIGEST-$TEST_EVIDENCE_DIGEST}" \
      --arg status "${TEST_INFO_STATUS-Accepted}" --arg mode "${TEST_INFO_MODE:-normal}" \
      '{id:$id,name:$name,sha256:$digest,status:$status,secret:"PRIVATE-CLIENT-OUTPUT"}
       | if $mode == "missing-bindings" then del(.name,.sha256) elif $mode == "null-bindings" then .name = null else . end'
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
      --arg status "${TEST_LOG_STATUS:-${TEST_INFO_STATUS:-${TEST_WAIT_STATUS:-Accepted}}}" --arg mode "${TEST_LOG_MODE:-normal}" \
      '{jobId:$id,status:$status,archiveFilename:$name,sha256:$digest,issues:[{severity:$severity,message:"fixture warning"}],secret:"PRIVATE-CLIENT-OUTPUT"}
       | if $mode == "missing-name" then del(.archiveFilename) elif $mode == "missing-hash" then del(.sha256)
         elif $mode == "multiple" then (. + {jobId:"00000000-0000-0000-0000-000000000000"}), . else . end' > "$path"
    ;;
  *) exit 92 ;;
esac
STUB
chmod +x "$work/bin/xcrun"
cat > "$work/bin/sleep" <<'STUB'
#!/bin/bash
# Accelerate only the observer watchdog for the hung-info fixture.
if [[ ${TEST_INFO_MODE:-normal} == hang && $1 == 30 ]]; then exec /bin/sleep 0.1; fi
exec /bin/sleep "$@"
STUB
chmod +x "$work/bin/sleep"
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
TEST_WAIT_MODE=transport TEST_INFO_MODE=transport expect_failure wait_for
expect_disposition wait_transport true
TEST_WAIT_MODE=malformed expect_failure wait_for
expect_disposition wait_started false
TEST_WAIT_STATUS='In Progress' expect_failure wait_for
expect_disposition apple_pending true
# Native notarytool timeout returns no JSON. Observe the retained UUID instead
# of treating absent wait evidence as a foreign submission or uploading again.
TEST_WAIT_MODE=native-timeout TEST_INFO_STATUS='In Progress' expect_failure wait_for
expect_disposition apple_pending true
jq -e '.status == "In Progress" and .wait_exit == 124 and .observation_source == "info" and .observation_exit == 0' "$work/state/app.status.json" >/dev/null || fail 'Native timeout lost its exit witness or authoritative pending observation.'
attempts=$(jq -r '.wait_attempts' "$work/state/app.recovery.json")
APPLE_NOTARY_DEVELOPER_DIR=/fixture/selected-notary-client TEST_WAIT_MODE=native-timeout wait_for > /dev/null
expect_disposition matching_accepted_log false
[[ $(tail -1 "$work/client-selection") == /fixture/selected-notary-client ]] || fail 'Info/log observation did not use the selected notary client.'
[[ $(tail -1 "$work/info-client-selection") == /fixture/selected-notary-client ]] || fail 'Info observation did not use the selected notary client.'
jq -e --argjson before "$attempts" '.wait_attempts == ($before + 1)' "$work/state/app.recovery.json" >/dev/null || fail 'Native timeout continuation lost its observation count.'
jq -e '.status == "Accepted" and .wait_exit == 124 and .observation_source == "info" and .observation_exit == 0 and (has("secret") | not)' "$work/state/app.status.json" >/dev/null || fail 'Successful info observation erased the original timeout.'
[[ $(wc -l < "$work/uploads" | tr -d ' ') == 1 ]] || fail 'Native timeout continuation submitted again.'
jq -n --arg digest "$TEST_EVIDENCE_DIGEST" \
  '{schema:2,commit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",run_id:"123",version:"9.8.7",build_number:"42",architecture:"universal",original_archive_sha256:$digest}' > "$work/state/origin.json"
"$root/scripts/checkpoint-macos.sh" "$work/state" "$work/info-checkpoint" > /dev/null
cmp -s "$work/state/app.status.json" "$work/info-checkpoint/app.status.json" || fail 'Checkpoint changed the original exit or info observation metadata.'
"$root/scripts/checkpoint-macos.sh" "$work/info-checkpoint" "$work/info-roundtrip" > /dev/null
diff -qr "$work/info-checkpoint" "$work/info-roundtrip" >/dev/null || fail 'Info observation checkpoint was not canonical on re-export.'
cp "$work/state/app.status.json" "$work/status-original.json"
jq '{id,status:"Unknown",wait_exit:124}' "$work/status-original.json" > "$work/state/app.status.json"
"$root/scripts/checkpoint-macos.sh" "$work/state" "$work/legacy-timeout" > /dev/null
cmp -s "$work/state/app.status.json" "$work/legacy-timeout/app.status.json" || fail 'Legacy Unknown/124 snapshot changed or gained optional null fields.'
cp "$work/status-original.json" "$work/state/app.status.json"
index=0
for mutation in '.observation_exit = null' '.observation_exit = "0"' '.observation_exit = -1' '.observation_exit = 0.5' '.observation_source = "private output"' 'del(.observation_source)' 'del(.observation_exit)'; do
  index=$((index + 1))
  jq "$mutation" "$work/status-original.json" > "$work/state/app.status.json"
  expect_failure "$root/scripts/checkpoint-macos.sh" "$work/state" "$work/invalid-observation-$index"
done
cp "$work/status-original.json" "$work/state/app.status.json"
for variable in TEST_INFO_ID TEST_INFO_NAME TEST_INFO_DIGEST TEST_INFO_STATUS; do
  case $variable in
    TEST_INFO_ID) value=00000000-0000-0000-0000-000000000000 ;;
    TEST_INFO_NAME) value=Other-Product.zip ;;
    TEST_INFO_DIGEST) value=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff ;;
    TEST_INFO_STATUS) value=Unknown ;;
  esac
  env TEST_WAIT_MODE=native-timeout "$variable=$value" "$root/scripts/notarize-stage.sh" wait app "$archive" "$work/state" > "$work/failure.log" 2>&1 && fail "Foreign/unknown info passed: $variable"
  expect_disposition wait_started false
done
TEST_WAIT_MODE=native-timeout TEST_INFO_ID='' expect_failure wait_for
for mode in malformed empty unauthorized unauthorized-json bad-types multiple contradictory-transport null-bindings; do
  TEST_WAIT_MODE=native-timeout TEST_INFO_MODE=$mode expect_failure wait_for
  expect_disposition wait_started false
done
TEST_WAIT_MODE=native-timeout TEST_INFO_MODE=missing-bindings wait_for > /dev/null
expect_disposition matching_accepted_log false
TEST_WAIT_MODE=native-timeout TEST_INFO_MODE=hang expect_failure wait_for
expect_disposition wait_started false
jq -e '.wait_exit == 124 and .observation_exit == 124 and .status == "Unknown"' "$work/state/app.status.json" >/dev/null || fail 'Hung info did not fail within its independent observation bound.'
TEST_WAIT_MODE=native-timeout TEST_LOG_DIGEST=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff expect_failure wait_for
TEST_WAIT_MODE=native-timeout TEST_LOG_NAME=Other-Product.zip expect_failure wait_for
TEST_WAIT_MODE=native-timeout TEST_LOG_ID=00000000-0000-0000-0000-000000000000 expect_failure wait_for
TEST_WAIT_MODE=native-timeout TEST_LOG_SEVERITY=error expect_failure wait_for
TEST_WAIT_MODE=native-timeout TEST_LOG_MODE=missing-name expect_failure wait_for
TEST_WAIT_MODE=native-timeout TEST_LOG_MODE=missing-hash expect_failure wait_for
TEST_WAIT_MODE=native-timeout TEST_LOG_STATUS=Rejected expect_failure wait_for
TEST_WAIT_MODE=native-timeout TEST_LOG_MODE=multiple expect_failure wait_for
TEST_WAIT_MODE=native-timeout TEST_LOG_MODE=missing expect_failure wait_for
TEST_WAIT_MODE=native-timeout TEST_LOG_MODE=unauthorized expect_failure wait_for
expect_disposition wait_started false
TEST_WAIT_MODE=native-timeout TEST_LOG_MODE=transport expect_failure wait_for
expect_disposition log_transport true
for status in Invalid Rejected; do
  TEST_WAIT_MODE=native-timeout TEST_INFO_STATUS=$status expect_failure wait_for
  expect_disposition apple_rejected false
  jq -e --arg status "$status" '.status == $status' "$work/state/app.log.json" >/dev/null || fail 'Rejected info observation lost its diagnostic log.'
done
infos=$(wc -l < "$work/infos" | tr -d ' ')
TEST_WAIT_ID=00000000-0000-0000-0000-000000000000 expect_failure wait_for
TEST_WAIT_MODE=malformed expect_failure wait_for
TEST_WAIT_STATUS=Unknown expect_failure wait_for
TEST_WAIT_MODE=unauthorized-empty expect_failure wait_for
[[ $(wc -l < "$work/infos" | tr -d ' ') == "$infos" ]] || fail 'Contradictory or malformed nonempty wait evidence was masked by info.'
APPLE_NOTARY_DEVELOPER_DIR=/fixture/selected-notary-client wait_for > /dev/null
[[ $(tail -1 "$work/client-selection") == /fixture/selected-notary-client ]] || fail 'Notarization did not use its explicitly selected client.'
wait_for > /dev/null
[[ $(tail -1 "$work/client-selection") == "${DEVELOPER_DIR:-default}" ]] || fail 'Notarization selection changed the caller toolchain.'
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
jq -e 'keys == ["id","status","wait_exit"]' "$work/safe/app.status.json" >/dev/null || fail 'Legacy checkpoint gained optional null observation fields.'
cmp -s "$work/state/app.status.json" "$work/safe/app.status.json" || fail 'Legacy status canonicalization changed.'
"$root/scripts/checkpoint-macos.sh" "$work/safe" "$work/legacy-roundtrip" > /dev/null
diff -qr "$work/safe" "$work/legacy-roundtrip" >/dev/null || fail 'Legacy checkpoint was not canonical on re-export.'
[[ -f $work/safe/$TEST_EVIDENCE_NAME && -f $work/safe/app.submission.json && -f $work/safe/app.log.json && -f $work/safe/app.intent.json ]] || fail 'Safe checkpoint lost required recovery files.'
[[ -f $work/safe/app.recovery.json ]] || fail 'Safe checkpoint lost its bound recovery disposition.'
[[ ! -e $work/safe/private && ! -e $work/safe/raw.stderr && ! -e $work/safe/signing.p8 ]] || fail 'Private files entered checkpoint.'
scan_result=0
grep -r -q 'PRIVATE-CLIENT-OUTPUT' "$work/safe" || scan_result=$?
[[ $scan_result == 1 ]] || fail 'Raw fields entered safe checkpoint or the leak scan failed.'
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
for fixture in intent-failure receipt-failure complete probe no-durable-probe; do
  mkdir "$work/$fixture"
  cp "$archive" "$work/$fixture/$TEST_EVIDENCE_NAME"
  cp "$work/state/origin.json" "$work/$fixture/origin.json"
done
uploads=$(wc -l < "$work/uploads" | tr -d ' ')
NW_DURABLE_EVENTS=true GITHUB_RUN_ID=899 GITHUB_RUN_ATTEMPT=1 TEST_EVENT_FAILURE=intent expect_failure "$work/hook-root/scripts/notarize-stage.sh" submit app "$work/intent-failure/$TEST_EVIDENCE_NAME" "$work/intent-failure"
[[ $(wc -l < "$work/uploads" | tr -d ' ') == "$uploads" ]] || fail 'Upload proceeded without durable intent.'
NW_DURABLE_EVENTS=true GITHUB_RUN_ID=899 GITHUB_RUN_ATTEMPT=1 TEST_EVENT_FAILURE=receipt expect_failure "$work/hook-root/scripts/notarize-stage.sh" submit app "$work/receipt-failure/$TEST_EVIDENCE_NAME" "$work/receipt-failure"
[[ -f $work/receipt-failure-intent-899/app.intent.json && -f $work/receipt-failure/app.submission.json ]] || fail 'Failed receipt custody lost its pre-upload reservation or local UUID.'
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
NW_DURABLE_EVENTS=false NW_RELEASE_PROBE=app expect_failure "$work/hook-root/scripts/notarize-stage.sh" submit app "$work/no-durable-probe/$TEST_EVIDENCE_NAME" "$work/no-durable-probe"
[[ $(wc -l < "$work/uploads" | tr -d ' ') == "$uploads" && ! -e $work/no-durable-probe/app.intent.json ]] || fail 'Probe ran without durable custody.'
NW_DURABLE_EVENTS=true NW_RELEASE_PROBE=app GITHUB_RUN_ID=903 GITHUB_RUN_ATTEMPT=1 expect_failure "$work/hook-root/scripts/notarize-stage.sh" submit app "$work/probe/$TEST_EVIDENCE_NAME" "$work/probe"
jq -e '.id != null and .retryable == true and .reason == "upload_returned_uuid" and .execution_run_id == "903"' "$work/probe-receipt-903/app.recovery.json" > /dev/null || fail 'Probe did not preserve a bound automatically recoverable real-submission receipt.'
[[ $(wc -l < "$work/uploads" | tr -d ' ') == "$((uploads + 1))" ]] || fail 'Probe uploaded more than once.'
NW_DURABLE_EVENTS=true NW_RELEASE_PROBE=app GITHUB_RUN_ID=904 GITHUB_RUN_ATTEMPT=1 "$work/hook-root/scripts/notarize-stage.sh" submit app "$work/probe/$TEST_EVIDENCE_NAME" "$work/probe" > /dev/null
[[ $(wc -l < "$work/uploads" | tr -d ' ') == "$((uploads + 1))" ]] || fail 'Probe repeated an existing UUID upload.'
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
