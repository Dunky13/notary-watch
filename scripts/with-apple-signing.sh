#!/bin/bash
{ set +x; } 2>/dev/null
set -euo pipefail
umask 077
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/lib/macos.sh"
# shellcheck source=scripts/lib/security-input.sh
source "$(dirname -- "$0")/lib/security-input.sh"
[[ $# -gt 0 ]] || nw_fail 'Pass the release operation to run.'
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted ]] || nw_fail 'Temporary signing Keychain setup is restricted to isolated GitHub-hosted runners.'
for name in APPLE_DEVELOPER_ID_P12_BASE64 APPLE_DEVELOPER_ID_P12_PASSWORD APPLE_NOTARY_KEY_P8 APPLE_SIGNING_IDENTITY APPLE_TEAM_ID APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER_ID; do
  [[ -n ${!name:-} ]] || nw_fail "Missing signing configuration: $name"
done
[[ $APPLE_TEAM_ID =~ ^[A-Z0-9]{10}$ && $APPLE_SIGNING_IDENTITY == 'Developer ID Application: '*" ($APPLE_TEAM_ID)" ]] || nw_fail 'Select a Developer ID Application identity for the configured team.'
work=$(mktemp -d "${RUNNER_TEMP:?}/notary-watch-signing.XXXXXX")
work=$(cd "$work" && pwd -P)
keychain="$work/signing.keychain-db"
keychain_created=false
search_changed=false
child_pid=
original=()
cleanup() {
  local result=${1:-$?}
  trap - EXIT
  trap '' INT TERM
  if [[ -n $child_pid ]]; then
    kill -TERM -- "-$child_pid" 2>/dev/null || true
    sleep 1
    kill -KILL -- "-$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
  if [[ $search_changed == true ]]; then
    security list-keychains -d user -s "${original[@]}" >/dev/null 2>&1 || result=1
    security list-keychains -d user > "$work/restored-search.txt" 2>/dev/null || result=1
    cmp -s "$work/original-search.txt" "$work/restored-search.txt" || result=1
  fi
  if [[ $keychain_created == true || -e $keychain ]]; then security delete-keychain "$keychain" >/dev/null 2>&1 || result=1; fi
  rm -rf -- "$work"
  exit "$result"
}
trap 'cleanup "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
security list-keychains -d user > "$work/original-search.txt"
while IFS= read -r line; do
  if [[ $line =~ ^[[:space:]]*\"([^\"]+)\"[[:space:]]*$ ]]; then original+=("${BASH_REMATCH[1]}");
  else nw_fail 'Could not safely capture the original Keychain search list.'; fi
done < "$work/original-search.txt"
[[ ${#original[@]} -gt 0 ]] || nw_fail 'Original Keychain search list is empty.'
printf '%s' "$APPLE_DEVELOPER_ID_P12_BASE64" | base64 -D > "$work/identity.p12"
printf '%s' "$APPLE_NOTARY_KEY_P8" > "$work/notary.p8"
[[ -s $work/identity.p12 && -s $work/notary.p8 ]] || nw_fail 'Decoded signing material is empty.'
keychain_password=$(openssl rand -hex 32)
# create-keychain itself changes the search list; enable restoration before it.
search_changed=true
nw_security_private create-keychain -p "$keychain_password" "$keychain" > "$work/keychain.log" 2>&1
keychain_created=true
{
  nw_security_private unlock-keychain -p "$keychain_password" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
  nw_security_private import "$work/identity.p12" -k "$keychain" -f pkcs12 -x -P "$APPLE_DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign
  nw_security_private set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain"
} >> "$work/keychain.log" 2>&1
security list-keychains -d user -s "${original[@]}" "$keychain"
security find-identity -v -p codesigning "$keychain" > "$work/identities.txt"
identity_count=0
identity_hash=
while IFS= read -r line; do
  if [[ $line =~ ([A-Fa-f0-9]{40})[[:space:]]+\"(.*)\" && ${BASH_REMATCH[2]} == "$APPLE_SIGNING_IDENTITY" ]]; then
    identity_hash=${BASH_REMATCH[1]}; identity_count=$((identity_count + 1))
  fi
done < "$work/identities.txt"
[[ $identity_count == 1 ]] || nw_fail 'Expected exactly one valid imported Developer ID Application identity.'
export APPLE_SIGNING_IDENTITY=$identity_hash APPLE_SIGNING_KEYCHAIN=$keychain NOTARY_KEY_FILE="$work/notary.p8"
unset APPLE_DEVELOPER_ID_P12_BASE64 APPLE_DEVELOPER_ID_P12_PASSWORD APPLE_NOTARY_KEY_P8 keychain_password
set -m
"$@" &
child_pid=$!
set +m
result=0
wait "$child_pid" || result=$?
cleanup "$result"
