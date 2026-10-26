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
    printf '{"id":"%s","status":"Accepted","secret":"PRIVATE-CLIENT-OUTPUT"}\n' "${TEST_WAIT_ID:-12345678-1234-1234-1234-123456789abc}"
    ;;
  log)
    path=${!#}
    [[ ${TEST_LOG_MODE:-normal} != missing ]] || exit 1
    [[ ${TEST_LOG_MODE:-normal} != no-output ]] || exit 0
    [[ ${TEST_LOG_MODE:-normal} != malformed ]] || { printf 'broken' > "$path"; exit 0; }
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
submit > /dev/null
jq -e '.schema == 2 and .commit == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .build == "42" and .ci_run_id == "123" and .architecture == "universal" and .id != null and (has("secret") | not)' "$work/state/app.submission.json" >/dev/null || fail 'Receipt lost provenance or included raw fields.'
submit > /dev/null
[[ $(wc -l < "$work/uploads" | tr -d ' ') == 1 ]] || fail 'Receipt caused a duplicate upload.'
mkdir "$work/state/app.lock"
expect_failure submit
rmdir "$work/state/app.lock"
[[ $(wc -l < "$work/uploads" | tr -d ' ') == 1 ]] || fail 'Concurrent receipt uploaded again.'
RELEASE_BUILD=43 expect_failure submit
BUILD_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb expect_failure submit
wait_for > /dev/null
jq -e '.issues[0].message == "fixture warning" and (has("secret") | not)' "$work/state/app.log.json" >/dev/null || fail 'Warning disappeared or raw diagnostic field leaked.'
TEST_LOG_DIGEST=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff expect_failure wait_for
TEST_LOG_NAME=Other-Product.zip expect_failure wait_for
TEST_LOG_ID=00000000-0000-0000-0000-000000000000 expect_failure wait_for
TEST_WAIT_ID=00000000-0000-0000-0000-000000000000 expect_failure wait_for
TEST_LOG_MODE=missing expect_failure wait_for
wait_for > /dev/null
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
[[ ! -e $work/safe/private && ! -e $work/safe/raw.stderr && ! -e $work/safe/signing.p8 ]] || fail 'Private files entered checkpoint.'
if rg -q 'PRIVATE-CLIENT-OUTPUT' "$work/safe"; then fail 'Raw fields entered safe checkpoint.'; fi
expect_failure "$root/scripts/checkpoint-macos.sh" "$work/state" "$work/safe"
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
