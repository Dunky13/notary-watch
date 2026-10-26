#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/lib/macos.sh"
cd "$NW_ROOT"
universal=false
app_output="$NW_ROOT/dist/Notary Watch.app"
while [[ $# -gt 0 ]]; do
  case $1 in
    --universal) universal=true; shift ;;
    --output) [[ $# -ge 2 ]] || nw_fail '--output needs an app path.'; app_output=$2; shift 2 ;;
    *) nw_fail 'Usage: build-app.sh [--universal] [--output path.app]' ;;
  esac
done
[[ $app_output == /* ]] || app_output="$PWD/$app_output"
[[ $app_output == *.app && ! -L $app_output ]] || nw_fail 'Output must be an app bundle, not a symlink.'
work=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-build.XXXXXX")
cleanup() {
  local result=$?
  if [[ -d $work/previous.app && ! -e $app_output ]]; then mv "$work/previous.app" "$app_output" || result=1; fi
  rm -rf -- "$work"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
app="$work/Notary Watch.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
if [[ $universal == true ]]; then
  for build_arch in arm64 x86_64; do
    triple="$build_arch-apple-macosx14.0"
    swift build -c release -j 2 --triple "$triple" --scratch-path ".build/$build_arch"
    binary_dir=$(swift build -c release --triple "$triple" --scratch-path ".build/$build_arch" --show-bin-path)
    cp "$binary_dir/NotaryWatch" "$work/$build_arch"
  done
  lipo -create "$work/arm64" "$work/x86_64" -output "$app/Contents/MacOS/NotaryWatch"
  nw_require_universal "$app/Contents/MacOS/NotaryWatch"
else
  swift build -c release -j 2
  binary_dir=$(swift build -c release --show-bin-path)
  cp "$binary_dir/NotaryWatch" "$app/Contents/MacOS/NotaryWatch"
fi
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -n ${BUILD_NUMBER:-} ]]; then
  [[ $BUILD_NUMBER =~ ^[0-9]+$ ]] || nw_fail 'BUILD_NUMBER must contain digits.'
  plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$app/Contents/Info.plist"
fi
swift scripts/make-icon.swift "$work/AppIcon.iconset"
iconutil -c icns "$work/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
chmod -R u+rwX,go+rX,go-w "$app"
xattr -cr "$app"
codesign --force --sign - "$app/Contents/MacOS/NotaryWatch"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
mkdir -p "$(dirname -- "$app_output")"
if [[ -e $app_output ]]; then
  [[ -f $app_output/Contents/Info.plist ]] || nw_fail 'Refusing to replace a directory that is not an app bundle.'
  mv "$app_output" "$work/previous.app"
fi
mv "$app" "$app_output"
printf '\nBuilt: %s\n' "$app_output"
