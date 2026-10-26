#!/bin/bash
set -euo pipefail
# The configured major/minor is product policy. CI allocates the patch exactly
# once, before compilation, so promotion/recovery never edits signed metadata.
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/../lib/macos.sh"
[[ ${GITHUB_RUN_NUMBER:-} =~ ^[1-9][0-9]*$ ]] || nw_fail 'CI version allocation requires its workflow run number.'
base=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$NW_ROOT/Resources/Info.plist")
nw_validate_version "$base"
printf '%s.%s\n' "${base%.*}" "$GITHUB_RUN_NUMBER"
