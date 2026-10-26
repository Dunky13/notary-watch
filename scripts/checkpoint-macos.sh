#!/bin/bash
# Export recovery state using an explicit allowlist; raw client files stay private.
set -euo pipefail
umask 077
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/lib/macos.sh"
[[ $# == 2 ]] || nw_fail 'Usage: checkpoint-macos.sh state-directory new-checkpoint-directory'
state=$1 output=$2
[[ -d $state && ! -L $state && -f $state/origin.json && ! -L $state/origin.json ]] || nw_fail 'No initialized release state exists to checkpoint.'
[[ ! -e $output && ! -L $output ]] || nw_fail 'Checkpoint destination already exists.'
[[ ! -e $state/app.lock && ! -e $state/installer.lock ]] || nw_fail 'Cannot snapshot an active notarization stage.'
mkdir -p "$(dirname -- "$output")"
work=$(mktemp -d "$(dirname -- "$output")/.checkpoint.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
jq -e '.schema == 2 and (.commit | test("^[a-f0-9]{40}$")) and (.run_id | test("^[1-9][0-9]*$"))
  and (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and (.build_number | test("^[1-9][0-9]*$"))
  and .architecture == "universal" and (.original_archive_sha256 | test("^[a-f0-9]{64}$"))' "$state/origin.json" >/dev/null || nw_fail 'Release origin is malformed.'
jq -S '{schema,commit,run_id,version,build_number,architecture,original_archive_sha256}' "$state/origin.json" > "$work/origin.json"
version=$(jq -r '.version' "$work/origin.json")
build=$(jq -r '.build_number' "$work/origin.json")
run=$(jq -r '.run_id' "$work/origin.json")
commit=$(jq -r '.commit' "$work/origin.json")
for stage in app installer; do
  kind=App extension=zip
  if [[ $stage == installer ]]; then kind=Installer; extension=dmg; fi
  name="Notary-Watch-$kind-$version-build.$build-$run-universal.$extension"
  for suffix in intent submission; do
    file="$state/$stage.$suffix.json"
    if [[ -e $file || -L $file ]]; then
      [[ -f $file && ! -L $file ]] || nw_fail 'Checkpoint receipt is not a regular file.'
      jq -e --arg stage "$stage" --arg name "$name" --arg commit "$commit" --arg version "$version" --arg build "$build" --arg run "$run" \
        '.schema == 2 and .stage == $stage and .archive == $name and .commit == $commit and .version == $version
         and .build == $build and .architecture == "universal" and .ci_run_id == $run and (.sha256 | test("^[a-f0-9]{64}$"))' "$file" >/dev/null || nw_fail 'Checkpoint receipt does not match its release origin.'
      if [[ $suffix == submission ]]; then
        jq -e '.id | test("^[A-Fa-f0-9]{8}(-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}$")' "$file" >/dev/null || nw_fail 'Checkpoint submission ID is invalid.'
        jq '{schema,stage,archive,sha256,commit,version,build,architecture,ci_run_id,id}' "$file" > "$work/$stage.$suffix.json"
      else
        jq '{schema,stage,archive,sha256,commit,version,build,architecture,ci_run_id}' "$file" > "$work/$stage.$suffix.json"
      fi
    fi
  done
  if [[ -f $work/$stage.submission.json ]]; then
    [[ -f $work/$stage.intent.json ]] || nw_fail 'Checkpoint submission has no intent.'
    jq -e --slurpfile intent "$work/$stage.intent.json" 'del(.id) == $intent[0]' "$work/$stage.submission.json" >/dev/null || nw_fail 'Checkpoint submission differs from its intent.'
  fi
  if [[ -e $state/$name || -L $state/$name ]]; then
    [[ -f $state/$name && ! -L $state/$name ]] || nw_fail 'Checkpoint archive is not a regular file.'
    if [[ -f $work/$stage.intent.json ]]; then
      [[ $(nw_sha "$state/$name") == "$(jq -r '.sha256' "$work/$stage.intent.json")" ]] || nw_fail 'Checkpoint archive differs from its submission intent.'
    fi
    cp "$state/$name" "$work/$name"
  elif [[ -e $work/$stage.intent.json || -e $work/$stage.submission.json ]]; then
    nw_fail 'Checkpoint lost an attempted submission archive.'
  fi
  for suffix in archive.sha256 prepared.sha256; do
    file="$state/$stage.$suffix"
    if [[ -e $file || -L $file ]]; then
      [[ -f $file && ! -L $file ]] || nw_fail 'Checkpoint digest is not a regular file.'
      digest=$(cat "$file")
      [[ $digest =~ ^[a-f0-9]{64}$ && -f $work/$name && $(nw_sha "$work/$name") == "$digest" ]] || nw_fail 'Checkpoint digest differs from its archive.'
      printf '%s\n' "$digest" > "$work/$stage.$suffix"
    fi
  done
  file="$state/$stage.status.json"
  if [[ -f $file && ! -L $file ]]; then
    jq '{id,status,wait_exit}' "$file" > "$work/$stage.status.json"
  fi
  file="$state/$stage.log.json"
  if [[ -f $file && ! -L $file ]]; then
    jq -e -f "$NW_ROOT/scripts/lib/notary-log.jq" "$file" > "$work/$stage.log.json"
  fi
done
mv "$work" "$output"
printf 'Saved safe notarization recovery checkpoint.\n'
