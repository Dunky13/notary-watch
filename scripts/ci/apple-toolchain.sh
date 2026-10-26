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
