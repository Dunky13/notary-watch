#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/../lib/macos.sh"
[[ $# == 1 ]] || nw_fail 'Usage: release-preflight.sh original-build-directory'
input=$1
[[ ${BUILD_SHA:-} =~ ^[a-f0-9]{40}$ && ${BUILD_RUN_ID:-} =~ ^[1-9][0-9]*$ && ${BUILD_NUMBER:-} =~ ^[1-9][0-9]*$ ]] || nw_fail 'Exact original CI identity is required.'
"$NW_ROOT/scripts/ci/apple-toolchain.sh"
git diff --exit-code
git diff --cached --exit-code
[[ $(git rev-parse HEAD) == "${GITHUB_SHA:?}" ]] || nw_fail 'Release automation checkout differs from its workflow commit.'
metadata="$input/build-metadata.json"
jq -e --arg sha "$BUILD_SHA" --arg run "$BUILD_RUN_ID" --arg build "$BUILD_NUMBER" \
  '.schema == 1 and .commit == $sha and .run_id == $run and .build_number == $build and .architecture == "universal"' "$metadata" >/dev/null || nw_fail 'Build metadata differs from the pinned successful main CI run.'
version=$(jq -er '.version' "$metadata")
nw_validate_version "$version"
archive="Notary-Watch-App-$version-universal-development.zip"
[[ $(jq -r '.archive' "$metadata") == "$archive" && -f $input/$archive ]] || nw_fail 'Unexpected original app archive.'
[[ $(nw_sha "$input/$archive") == "$(jq -er '.archive_sha256' "$metadata")" ]] || nw_fail 'Original archive checksum differs from CI metadata.'
(cd "$input" && shasum -a 256 -c SHA256SUMS)
work=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-preflight.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
ditto -x -k "$input/$archive" "$work"
app="$work/Notary Watch.app"
plist="$app/Contents/Info.plist"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist") == dev.notarywatch.local ]] || nw_fail 'Unexpected bundle identity.'
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist") == "$version" ]] || nw_fail 'Bundle version differs from CI metadata.'
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist") == "$BUILD_NUMBER" ]] || nw_fail 'Bundle build number differs from the original CI run.'
nw_require_universal "$app/Contents/MacOS/NotaryWatch"
codesign --verify --deep --strict "$app"
printf 'Preflight verified source %s, version %s, build %s, bundle dev.notarywatch.local, arm64 and x86_64.\n' "$BUILD_SHA" "$version" "$BUILD_NUMBER"
