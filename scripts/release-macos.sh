#!/bin/bash
{ set +x; } 2>/dev/null
set -euo pipefail
umask 077
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/lib/macos.sh"
[[ $# == 4 ]] || nw_fail 'Usage: release-macos.sh initialize|prepare|submit-app|finish-app|submit-installer|finish-installer source-directory state-directory output-directory'
operation=$1 source_dir=$2 state=$3 output=$4
[[ $operation =~ ^(initialize|prepare|submit-app|finish-app|submit-installer|finish-installer)$ ]] || nw_fail 'Invalid release operation.'
[[ ${BUILD_SHA:-} =~ ^[a-f0-9]{40}$ && ${BUILD_RUN_ID:-} =~ ^[1-9][0-9]*$ ]] || nw_fail 'Original CI build identity is missing.'
mkdir -p "$state"
state=$(cd "$state" && pwd -P)
metadata="$source_dir/build-metadata.json"
[[ -f $metadata ]] || nw_fail 'Build metadata is missing.'
jq -e --arg sha "$BUILD_SHA" --arg run "$BUILD_RUN_ID" \
  '.schema == 1 and .commit == $sha and .run_id == $run and .architecture == "universal"' "$metadata" >/dev/null || nw_fail 'Original CI provenance does not match.'
version=$(jq -er '.version' "$metadata")
nw_validate_version "$version"
build=$(jq -er '.build_number | select(type == "string" and test("^[1-9][0-9]*$"))' "$metadata") || nw_fail 'Original CI build number is missing or invalid.'
export RELEASE_VERSION="$version" RELEASE_BUILD="$build" RELEASE_ARCHITECTURE=universal
input="Notary-Watch-App-$version-universal-development.zip"
[[ $(jq -r '.archive' "$metadata") == "$input" ]] || nw_fail 'Unexpected original archive name.'
original="$source_dir/$input"
[[ -f $original && $(nw_sha "$original") == "$(jq -r '.archive_sha256' "$metadata")" ]] || nw_fail 'Original archive digest does not match.'
jq -nS --arg sha "$BUILD_SHA" --arg run "$BUILD_RUN_ID" --arg version "$version" --arg build "$build" --arg digest "$(nw_sha "$original")" \
  '{schema:2,commit:$sha,run_id:$run,version:$version,build_number:$build,architecture:"universal",original_archive_sha256:$digest}' > "$state/origin.expected.json"
if [[ -e $state/origin.json ]]; then
  cmp -s "$state/origin.json" "$state/origin.expected.json" || nw_fail 'Checkpoint belongs to a different build.'
else
  [[ $operation == initialize || $operation == prepare ]] || nw_fail 'Release state has not been initialized.'
  mv "$state/origin.expected.json" "$state/origin.json"
fi
if [[ $operation == initialize ]]; then
  printf 'Initialized credential-free release recovery state.\n'
  exit 0
fi
[[ -n ${APPLE_SIGNING_IDENTITY:-} && ${APPLE_TEAM_ID:-} =~ ^[A-Z0-9]{10}$ ]] || nw_fail 'Developer ID signing configuration is missing.'
app_zip="$state/Notary-Watch-App-$version-build.$build-$BUILD_RUN_ID-universal.zip"
dmg="$state/Notary-Watch-Installer-$version-build.$build-$BUILD_RUN_ID-universal.dmg"
app="$state/working/Notary Watch.app"
mkdir -p "$state/private"
restore_app() {
  mkdir -p "$state/working"
  rm -rf -- "$app"
  ditto -x -k "$app_zip" "$state/working"
  [[ -f $app/Contents/MacOS/NotaryWatch ]] || nw_fail 'Signed checkpoint app is incomplete.'
  [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist") == dev.notarywatch.local ]] || nw_fail 'Checkpoint app identifier changed.'
  [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist") == "$version" ]] || nw_fail 'Checkpoint app version changed.'
  [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist") == "$build" ]] || nw_fail 'Checkpoint app build changed.'
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
    xcrun stapler staple "$target" > "$state/private/$stage.staple.$attempt.log" 2>&1 || result=$?
    if [[ $result == 0 ]]; then
      xcrun stapler validate "$target" > "$state/private/$stage.validate.$attempt.log" 2>&1 || result=$?
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
    [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist") == "$build" ]] || nw_fail 'App build differs from CI metadata.'
    nw_require_universal "$app/Contents/MacOS/NotaryWatch"
    sign_target "$app/Contents/MacOS/NotaryWatch"
    sign_target "$app"
    nw_verify_developer_id "$app"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$app_zip.tmp"
    mv "$app_zip.tmp" "$app_zip"
    ;;
  submit-app)
    restore_app
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
    nw_verify_developer_id "$dmg"
    "$NW_ROOT/scripts/notarize-stage.sh" submit installer "$dmg" "$state"
    ;;
  finish-installer)
    "$NW_ROOT/scripts/notarize-stage.sh" wait installer "$dmg" "$state"
    restore_app
    staple_target "$app" app
    mkdir -p "$state/final"
    final_dmg="$state/final/$(basename "$dmg")"
    cp "$dmg" "$final_dmg"
    staple_target "$final_dmg" installer
    nw_verify_developer_id "$final_dmg"
    "$NW_ROOT/scripts/verify-macos.sh" "$final_dmg" release
    # Assemble beside the destination. A failed repack leaves previous good
    # output untouched; the rollback trap covers cancellation between renames.
    output_name=$(basename -- "$output")
    [[ $output_name != . && $output_name != .. && $output_name != / ]] || nw_fail 'Choose a dedicated release output directory.'
    mkdir -p "$(dirname -- "$output")"
    output_parent=$(cd "$(dirname -- "$output")" && pwd -P)
    output="$output_parent/$output_name"
    [[ ! -e $output || ( -d $output && ! -L $output ) ]] || nw_fail 'Release output must be a regular directory.'
    if [[ -d $output ]]; then
      [[ -f $output/release-manifest.json && -f $output/SHA256SUMS ]] || nw_fail 'Refusing to replace an output directory without a complete release.'
      (cd "$output" && shasum -a 256 -c SHA256SUMS) || nw_fail 'Previous output is incomplete; it was preserved for inspection.'
    fi
    next_output=$(mktemp -d "$output_parent/.notary-watch-release.XXXXXX")
    previous_output=
    finish_output() {
      local result=$?
      trap - EXIT
      trap '' INT TERM
      if [[ -n $previous_output && -e $previous_output && ! -e $output ]]; then
        mv "$previous_output" "$output" || result=1
      fi
      if [[ -n $next_output && -d $next_output ]]; then rm -rf -- "$next_output" || result=1; fi
      exit "$result"
    }
    trap finish_output EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # Recreate the ZIP after stapling so the installed app carries its ticket.
    ditto -c -k --sequesterRsrc --keepParent "$app" "$next_output/$(basename "$app_zip")"
    cp "$final_dmg" "$next_output/"
    jq -n --arg commit "$BUILD_SHA" --arg run "$BUILD_RUN_ID" --arg version "$version" --arg build "$build" --arg team "$APPLE_TEAM_ID" \
      --arg app_id "$(jq -er '.id' "$state/app.submission.json")" --arg installer_id "$(jq -er '.id' "$state/installer.submission.json")" \
      --arg app_sha "$(cat "$state/app.archive.sha256")" --arg installer_sha "$(cat "$state/installer.archive.sha256")" \
      '{product:"Notary Watch",version:$version,build_number:$build,architecture:"universal",commit:$commit,source_run_id:$run,team_id:$team,notarization:{app:$app_id,installer:$installer_id},submitted_sha256:{app:$app_sha,installer:$installer_sha}}' > "$next_output/release-manifest.json"
    (cd "$next_output" && shasum -a 256 "$(basename "$app_zip")" "$(basename "$dmg")" release-manifest.json > SHA256SUMS)
    (cd "$next_output" && shasum -a 256 -c SHA256SUMS)
    if [[ -e $output ]]; then
      previous_output="$next_output.previous"
      mv "$output" "$previous_output"
    fi
    mv "$next_output" "$output"
    next_output=
    if [[ -n $previous_output ]]; then rm -rf -- "$previous_output"; previous_output=; fi
    printf 'Finalized signed and notarized Notary Watch %s.\n' "$version"
    ;;
esac
