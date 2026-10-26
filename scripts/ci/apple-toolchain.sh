#!/bin/bash
set -euo pipefail
# CI uses the Xcode version that passed the native ARM and Intel qualification.
[[ ${DEVELOPER_DIR:-} == /Applications/Xcode_16.4.app/Contents/Developer && -d $DEVELOPER_DIR ]] || {
  printf 'The qualified Xcode 16.4 installation is required.\n' >&2; exit 1;
}
version=$(xcodebuild -version)
[[ ${version%%$'\n'*} == 'Xcode 16.4' ]] || { printf 'Unexpected Xcode version.\n' >&2; exit 1; }
printf '%s\n' "$version"
xcrun swift --version
xcrun notarytool --version
if [[ -n ${APPLE_NOTARY_DEVELOPER_DIR:-} ]]; then
  [[ $APPLE_NOTARY_DEVELOPER_DIR == /Applications/Xcode_26.3.app/Contents/Developer && -d $APPLE_NOTARY_DEVELOPER_DIR ]] || {
    printf 'The selected Xcode 26.3 notarization client is required.\n' >&2; exit 1;
  }
  notary_version=$(DEVELOPER_DIR="$APPLE_NOTARY_DEVELOPER_DIR" xcodebuild -version)
  [[ ${notary_version%%$'\n'*} == 'Xcode 26.3' ]] || { printf 'Unexpected notarization Xcode version.\n' >&2; exit 1; }
  printf 'Notarization client: %s\n' "$notary_version"
  DEVELOPER_DIR="$APPLE_NOTARY_DEVELOPER_DIR" xcrun notarytool --version
  DEVELOPER_DIR="$APPLE_NOTARY_DEVELOPER_DIR" xcrun notarytool submit --help > /dev/null
  DEVELOPER_DIR="$APPLE_NOTARY_DEVELOPER_DIR" xcrun notarytool info --help > /dev/null
fi
