#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/lib/macos.sh"
cd "$NW_ROOT"
app="$NW_ROOT/dist/Notary Watch.app"
output="$NW_ROOT/dist/packages"
while [[ $# -gt 0 ]]; do
  case $1 in
    --app) app=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    *) nw_fail 'Usage: package-macos.sh [--app path.app] [--output directory]' ;;
  esac
done
[[ -d $app && -f $app/Contents/MacOS/NotaryWatch ]] || nw_fail 'Build the app before packaging.'
[[ $app == /* ]] || app="$PWD/$app"
[[ $output == /* ]] || output="$PWD/$output"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
[[ $build_number =~ ^[1-9][0-9]*$ ]] || nw_fail 'App build number must be a positive integer.'
nw_validate_version "$version"
arch=$(nw_arch "$app/Contents/MacOS/NotaryWatch")
# These are explicitly development artifacts. Distribution replaces the signatures in a protected job.
base="Notary-Watch-Installer-$version-$arch-development"
zip_name="Notary-Watch-App-$version-$arch-development.zip"
mkdir -p "$output"
work=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-package.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$work/image"
ditto "$app" "$work/image/Notary Watch.app"
ln -s /Applications "$work/image/Applications"
cp "$NW_ROOT/Resources/Install.txt" "$work/image/Install.txt"
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/$zip_name"
nw_create_dmg "$work/image" "$work/$base.dmg" "Notary Watch $version"
hdiutil verify "$work/$base.dmg"
cp "$work/$zip_name" "$work/$base.dmg" "$output/"
(
  cd "$output"
  shasum -a 256 "$zip_name" "$base.dmg" > SHA256SUMS
)
if [[ -n ${GITHUB_SHA:-} ]]; then
  [[ $arch == universal ]] || nw_fail 'CI distribution requires a universal app.'
  jq -n --arg sha "$GITHUB_SHA" --arg run "$GITHUB_RUN_ID" --arg attempt "$GITHUB_RUN_ATTEMPT" \
    --arg version "$version" --arg build_number "$build_number" --arg archive "$zip_name" --arg dmg "$base.dmg" \
    --arg archive_sha256 "$(nw_sha "$output/$zip_name")" \
    '{schema:1,commit:$sha,run_id:$run,run_attempt:$attempt,version:$version,build_number:$build_number,architecture:"universal",archive:$archive,dmg:$dmg,archive_sha256:$archive_sha256}' > "$output/build-metadata.json"
fi
printf 'Drag-and-drop installer: %s/%s.dmg\n' "$output" "$base"
