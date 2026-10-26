#!/bin/bash
{ set +x; } 2>/dev/null
set -euo pipefail
umask 077
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/lib/macos.sh"
[[ $# == 4 ]] || nw_fail 'Usage: release-macos.sh prepare|submit-app|finish-app|submit-installer|finish-installer source-directory state-directory output-directory'
operation=$1 source_dir=$2 state=$3 output=$4
[[ $operation =~ ^(prepare|submit-app|finish-app|submit-installer|finish-installer)$ ]] || nw_fail 'Invalid release operation.'
[[ -n ${APPLE_SIGNING_IDENTITY:-} && ${APPLE_TEAM_ID:-} =~ ^[A-Z0-9]{10}$ ]] || nw_fail 'Developer ID signing configuration is missing.'
[[ -n ${BUILD_SHA:-} && ${BUILD_RUN_ID:-} =~ ^[0-9]+$ ]] || nw_fail 'Original CI build identity is missing.'
mkdir -p "$state"
state=$(cd "$state" && pwd -P)
metadata="$source_dir/build-metadata.json"
[[ -f $metadata ]] || nw_fail 'Build metadata is missing.'
jq -e --arg sha "$BUILD_SHA" --arg run "$BUILD_RUN_ID" \
  '.schema == 1 and .commit == $sha and .run_id == $run and .architecture == "universal"' "$metadata" >/dev/null || nw_fail 'Original CI provenance does not match.'
version=$(jq -er '.version' "$metadata")
nw_validate_version "$version"
input="Notary-Watch-App-$version-universal-development.zip"
[[ $(jq -r '.archive' "$metadata") == "$input" ]] || nw_fail 'Unexpected original archive name.'
original="$source_dir/$input"
[[ -f $original && $(nw_sha "$original") == "$(jq -r '.archive_sha256' "$metadata")" ]] || nw_fail 'Original archive digest does not match.'
jq -nS --arg sha "$BUILD_SHA" --arg run "$BUILD_RUN_ID" --arg version "$version" --arg digest "$(nw_sha "$original")" \
  '{commit:$sha,run_id:$run,version:$version,original_archive_sha256:$digest}' > "$state/origin.expected.json"
if [[ -e $state/origin.json ]]; then
  cmp -s "$state/origin.json" "$state/origin.expected.json" || nw_fail 'Checkpoint belongs to a different build.'
else
  [[ $operation == prepare ]] || nw_fail 'Release state has not been initialized.'
  mv "$state/origin.expected.json" "$state/origin.json"
fi
app_zip="$state/Notary-Watch-App-$version-universal.zip"
dmg="$state/Notary-Watch-Installer-$version-universal.dmg"
app="$state/working/Notary Watch.app"
restore_app() {
  mkdir -p "$state/working"
  rm -rf -- "$app"
  ditto -x -k "$app_zip" "$state/working"
  [[ -f $app/Contents/MacOS/NotaryWatch ]] || nw_fail 'Signed checkpoint app is incomplete.'
  nw_require_universal "$app/Contents/MacOS/NotaryWatch"
  nw_verify_developer_id "$app"
}
sign_target() {
  local target=$1
  local args=(--force --timestamp --sign "$APPLE_SIGNING_IDENTITY")
  if [[ -n ${APPLE_SIGNING_KEYCHAIN:-} ]]; then args+=(--keychain "$APPLE_SIGNING_KEYCHAIN"); fi
  if [[ $target != *.dmg ]]; then args+=(--options runtime); fi
  codesign "${args[@]}" "$target"
}
staple_target() {
  local target=$1 stage=$2 attempt result
  for attempt in 1 2 3; do
    result=0
    xcrun stapler staple "$target" > "$state/$stage.staple.$attempt.log" 2>&1 || result=$?
    if [[ $result == 0 ]]; then
      xcrun stapler validate "$target" > "$state/$stage.validate.$attempt.log" 2>&1 || result=$?
    fi
    [[ $result != 0 ]] || return 0
    printf 'Ticket attachment/validation failed for %s (attempt %s/3, exit %s).\n' "$stage" "$attempt" "$result" >&2
    [[ $result == 65 || $result == 68 ]] || return "$result"
    if [[ $attempt != 3 ]]; then sleep 2; fi
  done
  return "$result"
}
case $operation in
  prepare)
    if [[ -e $app_zip ]]; then restore_app; exit 0; fi
    [[ ! -e $state/app.intent.json && ! -e $state/app.submission.json ]] || nw_fail 'Checkpoint lost its submitted app archive.'
    mkdir -p "$state/working"
    # The input is a pinned artifact of successful main CI, never a PR upload.
    ditto -x -k "$original" "$state/working"
    [[ -f $app/Contents/MacOS/NotaryWatch ]] || nw_fail 'Original app is incomplete.'
    [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist") == dev.notarywatch.local ]] || nw_fail 'Unexpected app identifier.'
    [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist") == "$version" ]] || nw_fail 'App version differs from CI metadata.'
    nw_require_universal "$app/Contents/MacOS/NotaryWatch"
    sign_target "$app/Contents/MacOS/NotaryWatch"
    sign_target "$app"
    nw_verify_developer_id "$app"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$app_zip.tmp"
    mv "$app_zip.tmp" "$app_zip"
    ;;
  submit-app)
    "$NW_ROOT/scripts/notarize-stage.sh" submit app "$app_zip" "$state"
    ;;
  finish-app)
    "$NW_ROOT/scripts/notarize-stage.sh" wait app "$app_zip" "$state"
    restore_app
    staple_target "$app" app
    nw_verify_developer_id "$app"
    if [[ ! -f $state/installer.prepared.sha256 ]]; then
      [[ ! -e $state/installer.intent.json && ! -e $state/installer.submission.json ]] || nw_fail 'Checkpoint lost its prepared installer archive.'
      rm -f -- "$dmg"
      rm -rf -- "$state/image"
      mkdir "$state/image"
      ditto "$app" "$state/image/Notary Watch.app"
      ln -s /Applications "$state/image/Applications"
      cp "$NW_ROOT/Resources/Install.txt" "$state/image/Install.txt"
      nw_create_dmg "$state/image" "$dmg" "Notary Watch $version"
      sign_target "$dmg"
      nw_verify_developer_id "$dmg"
      nw_sha "$dmg" > "$state/installer.prepared.sha256"
    else
      [[ -f $dmg && $(nw_sha "$dmg") == "$(cat "$state/installer.prepared.sha256")" ]] || nw_fail 'Prepared installer bytes changed.'
    fi
    nw_verify_developer_id "$dmg"
    ;;
  submit-installer)
    "$NW_ROOT/scripts/notarize-stage.sh" submit installer "$dmg" "$state"
    ;;
  finish-installer)
    "$NW_ROOT/scripts/notarize-stage.sh" wait installer "$dmg" "$state"
    restore_app
    staple_target "$app" app
    mkdir -p "$state/final" "$output"
    final_dmg="$state/final/$(basename "$dmg")"
    cp "$dmg" "$final_dmg"
    staple_target "$final_dmg" installer
    nw_verify_developer_id "$final_dmg"
    "$NW_ROOT/scripts/verify-macos.sh" "$final_dmg" release
    # Recreate the ZIP after stapling so the installed app carries its ticket.
    ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$(basename "$app_zip")"
    cp "$final_dmg" "$output/"
    jq -n --arg commit "$BUILD_SHA" --arg run "$BUILD_RUN_ID" --arg version "$version" --arg team "$APPLE_TEAM_ID" \
      --arg app_id "$(jq -er '.id' "$state/app.submission.json")" --arg installer_id "$(jq -er '.id' "$state/installer.submission.json")" \
      '{product:"Notary Watch",version:$version,commit:$commit,source_run_id:$run,team_id:$team,notarization:{app:$app_id,installer:$installer_id}}' > "$output/release-manifest.json"
    (cd "$output" && shasum -a 256 "$(basename "$app_zip")" "$(basename "$dmg")" release-manifest.json > SHA256SUMS)
    printf 'Finalized signed and notarized Notary Watch %s.\n' "$version"
    ;;
esac
