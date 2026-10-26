#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/lib/macos.sh"
[[ $# -ge 1 && $# -le 2 ]] || nw_fail 'Usage: verify-macos.sh image.dmg [development|release]'
image=$1
mode=${2:-development}
[[ $mode == development || $mode == release ]] || nw_fail 'Invalid verification mode.'
[[ -f $image ]] || nw_fail 'Disk image not found.'
work=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-verify.XXXXXX")
mounted=false
cleanup() {
  local result=$?
  if [[ $mounted == true ]]; then hdiutil detach "$work/mount" -quiet || result=1; fi
  rm -rf -- "$work"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$work/mount" "$work/Applications"
hdiutil verify "$image"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$work/mount" "$image"
mounted=true
[[ -L $work/mount/Applications && $(readlink "$work/mount/Applications") == /Applications ]] || nw_fail 'Applications drag target is missing.'
app="$work/mount/Notary Watch.app"
[[ -f $app/Contents/MacOS/NotaryWatch && -f $work/mount/Install.txt ]] || nw_fail 'Installer contents are incomplete.'
codesign --verify --deep --strict "$app"
# Exercise the Finder copy result in an owned temporary Applications directory.
ditto "$app" "$work/Applications/Notary Watch.app"
copy="$work/Applications/Notary Watch.app"
codesign --verify --deep --strict "$copy"
[[ $(nw_sha "$app/Contents/MacOS/NotaryWatch") == "$(nw_sha "$copy/Contents/MacOS/NotaryWatch")" ]] || nw_fail 'The installed executable changed during copying.'
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$copy/Contents/Info.plist") == dev.notarywatch.local ]] || nw_fail 'Unexpected bundle identifier.'
if [[ $mode == release ]]; then
  nw_verify_developer_id "$image"
  nw_verify_developer_id "$copy"
  nw_validate_ticket "$image"
  nw_validate_ticket "$copy"
  # Test downloaded-app policy on the owned copy, retaining the original assets.
  xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");NotaryWatchAcceptance;" "$copy"
  spctl --assess --type execute --verbose=2 "$copy"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$image"
fi
printf 'Verified drag-and-drop copy (%s, %s).\n' "$(nw_arch "$copy/Contents/MacOS/NotaryWatch")" "$mode"
