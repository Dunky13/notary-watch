#!/bin/bash
# Shared macOS packaging helpers. Source from a script with set -euo pipefail.
NW_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
nw_fail() { printf 'Notary Watch: %s\n' "$*" >&2; exit 1; }
nw_version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$NW_ROOT/Resources/Info.plist"; }
nw_validate_version() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || nw_fail 'Version must be numeric x.y.z.'; }
nw_sha() { shasum -a 256 "$1" | awk '{print $1}'; }
nw_notarytool() {
  if [[ -n ${APPLE_NOTARY_DEVELOPER_DIR:-} ]]; then
    DEVELOPER_DIR="$APPLE_NOTARY_DEVELOPER_DIR" xcrun notarytool "$@"
  else
    xcrun notarytool "$@"
  fi
}
nw_arch() {
  local architectures
  architectures=$(lipo -archs "$1") || nw_fail 'Could not inspect executable architectures.'
  if [[ " $architectures " == *' arm64 '* && " $architectures " == *' x86_64 '* ]]; then printf universal;
  elif [[ $architectures == arm64 ]]; then printf arm64;
  elif [[ $architectures == x86_64 ]]; then printf x86_64;
  else nw_fail 'Unsupported macOS executable architecture.'; fi
}
nw_require_universal() {
  # -archs has stable argument parsing across Xcode's different lipo versions.
  [[ $(nw_arch "$1") == universal ]] || nw_fail 'Both arm64 and x86_64 executable slices are required.'
}
nw_create_dmg() {
  local source=$1 target=$2 volume=$3 attempt=1 status scratch
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-image.XXXXXX")
  printf 'hdiutil: create failed - Resource busy\n' > "$scratch/busy"
  while :; do
    if hdiutil create -quiet -nospotlight -fs HFS+ -format UDZO -volname "$volume" \
      -srcfolder "$source" "$target" 2> "$scratch/error"; then
      rm -rf -- "$scratch"; return 0
    else status=$?; fi
    cat "$scratch/error" >&2
    printf 'DMG creation failed (attempt %s/3, exit %s).\n' "$attempt" "$status" >&2
    if [[ $attempt -ge 3 ]] || ! cmp -s "$scratch/busy" "$scratch/error"; then
      rm -rf -- "$scratch"; return "$status"
    fi
    rm -f -- "$target"
    sleep 2
    attempt=$((attempt + 1))
  done
}
nw_verify_developer_id() {
  local target=$1 details
  [[ ${APPLE_TEAM_ID:-} =~ ^[A-Z0-9]{10}$ ]] || nw_fail 'Set a valid APPLE_TEAM_ID.'
  codesign --verify --deep --strict -R "=anchor apple generic and certificate leaf[subject.OU] = \"$APPLE_TEAM_ID\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists" "$target"
  details=$(codesign --display --verbose=4 "$target" 2>&1)
  printf '%s\n' "$details" | grep -Fx "TeamIdentifier=$APPLE_TEAM_ID" >/dev/null || nw_fail 'Unexpected signing team.'
  if [[ $target == *.app ]]; then
    printf '%s\n' "$details" | grep -E 'flags=.*runtime' >/dev/null || nw_fail 'Hardened Runtime is missing.'
  fi
}
