#!/bin/bash
{ set +x; } 2>/dev/null
set -euo pipefail
umask 077
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/lib/macos.sh"
[[ $# == 4 ]] || nw_fail 'Usage: notarize-stage.sh submit|wait app|installer archive state-directory'
operation=$1 stage=$2 archive=$3 state=$4
[[ $operation == submit || $operation == wait ]] || nw_fail 'Invalid notarization operation.'
[[ $stage == app || $stage == installer ]] || nw_fail 'Invalid notarization stage.'
[[ -f $archive ]] || nw_fail 'Submission archive is missing.'
[[ ${BUILD_SHA:-} =~ ^[a-f0-9]{40}$ && ${BUILD_RUN_ID:-} =~ ^[1-9][0-9]*$ ]] || nw_fail 'Source commit and CI run are required for a notarization receipt.'
nw_validate_version "${RELEASE_VERSION:-}"
[[ ${RELEASE_BUILD:-} =~ ^[1-9][0-9]*$ && ${RELEASE_ARCHITECTURE:-} == universal ]] || nw_fail 'Release build and architecture are required for a notarization receipt.'
kind=App extension=zip
if [[ $stage == installer ]]; then kind=Installer; extension=dmg; fi
name="Notary-Watch-$kind-$RELEASE_VERSION-build.$RELEASE_BUILD-$BUILD_RUN_ID-universal.$extension"
[[ $(basename "$archive") == "$name" ]] || nw_fail 'Submission filename does not match the release identity.'
mkdir -p "$state"
state=$(cd "$state" && pwd -P)
prefix="$state/$stage"
# No stale-lock recovery: interruption after an upload may require reconciliation.
mkdir "$prefix.lock" 2>/dev/null || nw_fail 'This notarization stage is already in use; reconcile the active operation before retrying.'
cleanup() {
  local result=$?
  trap - EXIT
  rm -f -- "$prefix.context.tmp"
  rmdir "$prefix.lock" || result=1
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$state/private"
raw="$state/private/$stage"
if [[ -n ${NOTARY_KEY_FILE:-} ]]; then
  [[ -s $NOTARY_KEY_FILE && -n ${APPLE_NOTARY_KEY_ID:-} && -n ${APPLE_NOTARY_ISSUER_ID:-} ]] || nw_fail 'Notary API key configuration is incomplete.'
  auth=(--key "$NOTARY_KEY_FILE" --key-id "$APPLE_NOTARY_KEY_ID" --issuer "$APPLE_NOTARY_ISSUER_ID")
else
  [[ -n ${NOTARY_KEYCHAIN_PROFILE:-} ]] || nw_fail 'Set NOTARY_KEYCHAIN_PROFILE or the API-key configuration.'
  auth=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
fi
get_id() {
  jq -er '.id | select(type == "string" and test("^[A-Fa-f0-9]{8}(-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}$"))' "$prefix.submission.json"
}
digest=$(nw_sha "$archive")
jq -nS --arg stage "$stage" --arg name "$name" --arg sha256 "$digest" \
  --arg commit "$BUILD_SHA" --arg version "$RELEASE_VERSION" --arg build "$RELEASE_BUILD" \
  --arg architecture "$RELEASE_ARCHITECTURE" --arg run "$BUILD_RUN_ID" \
  '{schema:2,stage:$stage,archive:$name,sha256:$sha256,commit:$commit,version:$version,build:$build,architecture:$architecture,ci_run_id:$run}' > "$prefix.context.tmp"
if [[ -f $prefix.archive.sha256 ]]; then
  [[ $(cat "$prefix.archive.sha256") == "$digest" ]] || nw_fail 'Submitted archive bytes changed. Refusing to resume or resubmit.'
fi
for record in "$prefix.intent.json" "$prefix.submission.json"; do
  if [[ -e $record ]]; then
    jq -e --slurpfile context "$prefix.context.tmp" 'del(.id) == $context[0]' "$record" >/dev/null || nw_fail 'Stored notarization receipt does not match the release identity.'
  fi
done
# This allowlisted disposition is an orchestration hint, never Apple evidence.
# Bind it to the exact receipt and replace stale retry hints before any action.
wait_attempts=0
previous_retryable=false
if [[ -e $prefix.recovery.json ]]; then
  jq -e --slurpfile context "$prefix.context.tmp" \
    'del(.id,.operation,.outcome,.reason,.retryable,.wait_attempts,.execution_run_id,.execution_attempt) == $context[0]
     and (.wait_attempts | type == "number" and . >= 0 and . == floor)
     and (.retryable | type == "boolean")' \
    "$prefix.recovery.json" >/dev/null || nw_fail 'Stored recovery disposition differs from the release identity.'
  wait_attempts=$(jq -r '.wait_attempts' "$prefix.recovery.json")
  previous_retryable=$(jq -r '.retryable' "$prefix.recovery.json")
fi
submission=
if [[ -f $prefix.submission.json ]]; then submission=$(get_id) || nw_fail 'Stored submission ID is invalid.'; fi
disposition() {
  local outcome=$1 reason=$2 retryable=$3
  jq -S --arg id "$submission" --arg operation "$operation" --arg outcome "$outcome" --arg reason "$reason" \
    --arg execution_run "${GITHUB_RUN_ID:-}" --arg execution_attempt "${GITHUB_RUN_ATTEMPT:-}" \
    --argjson retryable "$retryable" --argjson attempts "$wait_attempts" \
    '. + {id:(if $id == "" then null else $id end),operation:$operation,outcome:$outcome,reason:$reason,retryable:$retryable,wait_attempts:$attempts,
      execution_run_id:(if $execution_run == "" then null else $execution_run end),execution_attempt:(if $execution_attempt == "" then null else $execution_attempt end)}' \
    "$prefix.context.tmp" > "$prefix.recovery.json.tmp"
  mv "$prefix.recovery.json.tmp" "$prefix.recovery.json"
}
transport_failure() {
  # Retry only diagnosed URL transport failures. Authentication, arbitrary
  # stderr, malformed JSON and mismatched evidence remain terminal.
  local file=$1
  ! grep -Eiq 'HTTP[ /:]+(401|403)|unauthorized|forbidden|invalid credentials' "$file" &&
    grep -Eq 'NSURLErrorDomain Code=-(1001|1005|1009)([^0-9]|$)|The request timed out\.|The network connection was lost\.' "$file"
}
persist_event() {
  # Fixed trusted repository code, never an artifact-supplied command. Durable
  # intent must exist before upload; a UUID must reach custody immediately.
  if [[ ${NW_DURABLE_EVENTS:-false} == true ]]; then
    "$NW_ROOT/scripts/ci/persist-notary-event.sh" "$state" "$stage" "$1"
  fi
}
disposition failed operation_started false
if [[ $operation == submit ]]; then
  if [[ -f $prefix.submission.json ]]; then
    [[ -f $prefix.archive.sha256 && -f $prefix.intent.json ]] || nw_fail 'Submission receipt has no archive digest or intent.'
    submission=$(get_id) || nw_fail 'Stored submission ID is invalid.'
    if [[ $previous_retryable == true ]]; then
      disposition submitted upload_returned_uuid true
    else
      # A known UUID does not erase a recorded terminal rejection, contradictory
      # evidence, or successful wait followed by a later verification failure.
      disposition submitted existing_uuid false
    fi
    persist_event receipt
    printf 'Resume %s: %s (%s). No new upload.\n' "$stage" "$submission" "$name"
    exit 0
  fi
  if [[ -e $prefix.intent.json ]]; then
    disposition ambiguous reconcile_upload false
    nw_fail 'An upload was already attempted without a recoverable ID. Reconcile Apple history before any new submission.'
  fi
  printf '%s\n' "$digest" > "$prefix.archive.sha256"
  cp "$prefix.context.tmp" "$prefix.intent.json.tmp"
  mv "$prefix.intent.json.tmp" "$prefix.intent.json"
  persist_event intent
  result=0
  xcrun notarytool submit "$archive" "${auth[@]}" --output-format json --no-progress \
    > "$raw.submission.json" 2> "$raw.submit.stderr" || result=$?
  if submission=$(jq -er '.id | select(type == "string" and test("^[A-Fa-f0-9]{8}(-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}$"))' "$raw.submission.json" 2>/dev/null); then
    jq -S --arg id "$submission" '. + {id:$id}' "$prefix.context.tmp" > "$prefix.submission.json.tmp"
    mv "$prefix.submission.json.tmp" "$prefix.submission.json"
    # Retained UUIDs can always continue observation after runner loss. This
    # permits no second upload and grants no acceptance or publication authority.
    disposition submitted upload_returned_uuid true
    persist_event receipt
    printf 'Apple submission: %s, stage: %s, archive: %s.\n' "$submission" "$stage" "$name"
  else
    disposition ambiguous reconcile_upload false
    nw_fail 'Upload returned no valid submission ID. The safe intent was retained; reconcile Apple history before retrying.'
  fi
  [[ $result == 0 ]] || nw_fail "Upload exited $result. Its ID was retained for recovery."
  exit 0
fi
[[ -f $prefix.archive.sha256 && -f $prefix.submission.json && -f $prefix.intent.json ]] || nw_fail 'No recorded submission is available to wait for.'
submission=$(get_id) || nw_fail 'Invalid recorded submission ID.'
notary_timeout=${APPLE_NOTARY_TIMEOUT:-10m}
[[ $notary_timeout =~ ^([1-9][0-9]{0,4})([smh]?)$ ]] || nw_fail 'Notarization timeout must be a positive duration.'
seconds=${BASH_REMATCH[1]}
case ${BASH_REMATCH[2]} in m) seconds=$((seconds * 60));; h) seconds=$((seconds * 3600));; esac
((seconds <= 1800)) || nw_fail 'Notarization waits are limited to 30 minutes per stage.'
wait_attempts=$((wait_attempts + 1))
disposition failed wait_started false
wait_result=0
xcrun notarytool wait "$submission" "${auth[@]}" --timeout "$notary_timeout" --output-format json --no-progress \
  > "$raw.status.json" 2> "$raw.wait.stderr" || wait_result=$?
status=$(jq -r '.status | select(. == "Accepted" or . == "Invalid" or . == "Rejected" or . == "In Progress")' "$raw.status.json" 2>/dev/null) || status=
[[ -n $status ]] || status=Unknown
jq -n --arg id "$submission" --arg status "$status" --argjson exit "$wait_result" \
  '{id:$id,status:$status,wait_exit:$exit}' > "$prefix.status.json"
# Reject a mismatched wait response even when a later log would look valid.
if [[ $status == Unknown && $wait_result != 0 && ! -s $raw.status.json ]] && transport_failure "$raw.wait.stderr"; then
  disposition pending wait_transport true
  nw_fail 'Notarization wait had a diagnosed transport failure. Resume the recorded UUID.'
fi
jq -e --arg id "$submission" 'type == "object" and ((.id == null) or ((.id | ascii_downcase) == ($id | ascii_downcase)))' "$raw.status.json" >/dev/null 2>&1 || nw_fail 'Wait response does not match the recorded submission.'
case $status in
  'In Progress') disposition pending apple_pending true ;;
  Invalid|Rejected) disposition rejected apple_rejected false ;;
esac
log_result=0
case $status in
  Accepted|Invalid|Rejected)
    rm -f -- "$raw.log.json" "$prefix.log.json" "$prefix.log.json.tmp"
    xcrun notarytool log "$submission" "${auth[@]}" "$raw.log.json" > "$raw.log.stdout" 2> "$raw.log.stderr" || log_result=$?
    # Upload only documented diagnostic fields, never arbitrary client output.
    if [[ $log_result == 0 && -s $raw.log.json ]]; then
      jq -e -f "$NW_ROOT/scripts/lib/notary-log.jq" "$raw.log.json" > "$prefix.log.json.tmp" 2>/dev/null || nw_fail 'Apple returned malformed diagnostic evidence.'
      mv "$prefix.log.json.tmp" "$prefix.log.json"
    fi
    ;;
esac
# Contradictory diagnostics remain terminal even if the wait client also had a
# transport failure. Never classify a returned mismatched log as retryable.
if [[ $status == Accepted && $log_result == 0 && -s $prefix.log.json ]]; then
  jq -e --arg id "$submission" --arg name "$name" --arg digest "$digest" \
    '.status == "Accepted" and (.jobId | ascii_downcase) == ($id | ascii_downcase)
     and (.archiveFilename == null or .archiveFilename == $name)
     and (.sha256 == null or (.sha256 | ascii_downcase) == $digest)
     and all(.issues[]?; .severity != "error")' \
    "$prefix.log.json" >/dev/null || nw_fail 'Accepted log does not match the recorded submission, filename, or submitted digest.'
fi
if [[ $status == Accepted && $wait_result != 0 ]] && transport_failure "$raw.wait.stderr"; then
  disposition pending wait_transport true
fi
[[ $wait_result == 0 && $status == Accepted ]] || nw_fail "$stage is $status (wait exit $wait_result). Resume submission $submission; do not resubmit its archive."
if [[ $log_result != 0 ]] && transport_failure "$raw.log.stderr"; then
  disposition pending log_transport true
fi
[[ $log_result == 0 && -s $prefix.log.json ]] || nw_fail 'Accepted submission log could not be retrieved. Resume to fetch it before distribution.'
disposition accepted matching_accepted_log false
printf 'Accepted by Apple: %s (%s). Diagnostic log retained.\n' "$stage" "$submission"
