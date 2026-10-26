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
mkdir -p "$state"
prefix="$state/$stage"
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
if [[ -f $prefix.archive.sha256 ]]; then
  [[ $(cat "$prefix.archive.sha256") == "$digest" ]] || nw_fail 'Submitted archive bytes changed. Refusing to resume or resubmit.'
fi
if [[ $operation == submit ]]; then
  if [[ -f $prefix.submission.json ]]; then
    [[ -f $prefix.archive.sha256 ]] || nw_fail 'Submission receipt has no archive digest.'
    submission=$(get_id) || nw_fail 'Stored submission ID is invalid.'
    printf 'Resume %s: %s (%s). No new upload.\n' "$stage" "$submission" "$(basename "$archive")"
    exit 0
  fi
  [[ ! -e $prefix.intent.json ]] || nw_fail 'An upload was already attempted without a recoverable ID. Reconcile Apple history before any new submission.'
  printf '%s\n' "$digest" > "$prefix.archive.sha256"
  jq -n --arg stage "$stage" --arg name "$(basename "$archive")" --arg sha256 "$digest" \
    '{stage:$stage,archive:$name,sha256:$sha256}' > "$prefix.intent.json"
  result=0
  xcrun notarytool submit "$archive" "${auth[@]}" --output-format json --no-progress \
    > "$prefix.submission.json.tmp" 2> "$prefix.submit.stderr" || result=$?
  if jq -e '.id | select(type == "string" and test("^[A-Fa-f0-9]{8}(-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}$"))' "$prefix.submission.json.tmp" >/dev/null 2>&1; then
    mv "$prefix.submission.json.tmp" "$prefix.submission.json"
    printf 'Apple submission: %s, stage: %s, archive: %s.\n' "$(get_id)" "$stage" "$(basename "$archive")"
  else
    nw_fail 'Upload returned no valid submission ID. The intent and response were retained; do not blindly retry.'
  fi
  [[ $result == 0 ]] || nw_fail "Upload exited $result. Its ID was retained for recovery."
  exit 0
fi
[[ -f $prefix.archive.sha256 && -f $prefix.submission.json ]] || nw_fail 'No recorded submission is available to wait for.'
submission=$(get_id) || nw_fail 'Invalid recorded submission ID.'
notary_timeout=${APPLE_NOTARY_TIMEOUT:-10m}
[[ $notary_timeout =~ ^([1-9][0-9]{0,4})([smh]?)$ ]] || nw_fail 'Notarization timeout must be a positive duration.'
seconds=${BASH_REMATCH[1]}
case ${BASH_REMATCH[2]} in m) seconds=$((seconds * 60));; h) seconds=$((seconds * 3600));; esac
((seconds <= 1800)) || nw_fail 'Notarization waits are limited to 30 minutes per stage.'
wait_result=0
xcrun notarytool wait "$submission" "${auth[@]}" --timeout "$notary_timeout" --output-format json --no-progress \
  > "$prefix.status.json" 2> "$prefix.wait.stderr" || wait_result=$?
status=$(jq -r '.status // "Unknown"' "$prefix.status.json" 2>/dev/null) || status=Unknown
log_result=0
case $status in
  Accepted|Invalid|Rejected)
    xcrun notarytool log "$submission" "${auth[@]}" "$prefix.log.json" > "$prefix.log.stdout" 2> "$prefix.log.stderr" || log_result=$?
    ;;
esac
[[ $wait_result == 0 && $status == Accepted ]] || nw_fail "$stage is $status (wait exit $wait_result). Resume submission $submission; do not resubmit its archive."
[[ $log_result == 0 && -s $prefix.log.json ]] || nw_fail 'Accepted submission log could not be retrieved. Resume to fetch it before distribution.'
jq -e --arg id "$submission" '.status == "Accepted" and (.jobId | ascii_downcase) == ($id | ascii_downcase)' \
  "$prefix.log.json" >/dev/null || nw_fail 'Accepted log does not match the recorded submission.'
printf 'Accepted by Apple: %s (%s). Diagnostic log retained.\n' "$stage" "$submission"
