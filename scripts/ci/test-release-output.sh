#!/bin/bash
# Execute the real finalization and install-verification flow with synthetic Apple
# services. Real archive packing, checksums, and directory promotion run locally.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-output-tests.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/repository/scripts/lib" "$work/bin" "$work/input" "$work/state" "$work/outputs/release" "$work/image"
cp "$root/scripts/release-macos.sh" "$root/scripts/notarize-stage.sh" "$root/scripts/verify-macos.sh" "$work/repository/scripts/"
cp "$root/scripts/lib/macos.sh" "$root/scripts/lib/notary-log.jq" "$work/repository/scripts/lib/"
export TEST_OUTPUT_ROOT="$work" PATH="$work/bin:$PATH"
export BUILD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa BUILD_RUN_ID=123 RELEASE_VERSION=9.8.7 RELEASE_BUILD=42 RELEASE_ARCHITECTURE=universal
export APPLE_TEAM_ID=AB12CD34E5 APPLE_SIGNING_IDENTITY='Developer ID Application: Fixture (AB12CD34E5)' NOTARY_KEYCHAIN_PROFILE=fixture
unset NOTARY_KEY_FILE
cat > "$work/bin/xcrun" <<'STUB'
#!/bin/bash
set -euo pipefail
if [[ $1 == stapler ]]; then
  [[ $2 == staple || $2 == validate ]] || exit 91
  exit 0
fi
[[ $1 == notarytool ]] || exit 92
case $2 in
  submit)
    printf '{"id":"12345678-1234-1234-1234-123456789abc"}\n' ;;
  wait)
    printf '{"id":"12345678-1234-1234-1234-123456789abc","status":"Accepted"}\n' ;;
  log)
    jq -n '{jobId:"12345678-1234-1234-1234-123456789abc",status:"Accepted",issues:null}' > "${!#}" ;;
  *) exit 93 ;;
esac
STUB
cat > "$work/bin/codesign" <<'STUB'
#!/bin/bash
set -euo pipefail
if [[ $1 == --display ]]; then printf 'TeamIdentifier=AB12CD34E5\nCodeDirectory flags=0x10000(runtime)\n' >&2; fi
STUB
cat > "$work/bin/lipo" <<'STUB'
#!/bin/bash
[[ $1 == -archs ]] || exit 94
printf 'arm64 x86_64\n'
STUB
cat > "$work/bin/hdiutil" <<'STUB'
#!/bin/bash
set -euo pipefail
case $1 in
  verify) ;;
  attach)
    shift
    while [[ $# -gt 0 ]]; do
      if [[ $1 == -mountpoint ]]; then
        /usr/bin/ditto "$TEST_OUTPUT_ROOT/image" "$2"
        exit 0
      fi
      shift
    done
    exit 95 ;;
  detach) printf 'detached\n' >> "$TEST_OUTPUT_ROOT/mount-cleanup" ;;
  *) exit 96 ;;
esac
STUB
cat > "$work/bin/spctl" <<'STUB'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_OUTPUT_ROOT/assessments"
[[ ${TEST_REJECT_INSTALL:-false} != true ]] || exit 45
STUB
cat > "$work/bin/ditto" <<'STUB'
#!/bin/bash
set -euo pipefail
target=${!#}
if [[ ${TEST_FAIL_FINAL_ZIP:-false} == true && $1 == -c && $target == *'/.notary-watch-release.'* ]]; then
  printf 'partial final archive\n' > "$target"
  printf 'final-zip-failed\n' >> "$TEST_OUTPUT_ROOT/packing"
  exit 46
fi
exec /usr/bin/ditto "$@"
STUB
cat > "$work/bin/gh" <<'STUB'
#!/bin/bash
printf 'Unexpected publication call\n' > "$TEST_OUTPUT_ROOT/publication"
exit 97
STUB
chmod +x "$work/bin/"*
app="$work/image/Notary Watch.app"
mkdir -p "$app/Contents/MacOS"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 9.8.7' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 42' "$app/Contents/Info.plist"
printf 'synthetic executable; never launched\n' > "$app/Contents/MacOS/NotaryWatch"
chmod +x "$app/Contents/MacOS/NotaryWatch"
ln -s /Applications "$work/image/Applications"
cp "$root/Resources/Install.txt" "$work/image/Install.txt"
suffix=9.8.7-build.42-123-universal
app_archive="Notary-Watch-App-$suffix.zip"
installer_archive="Notary-Watch-Installer-$suffix.dmg"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$work/state/$app_archive"
printf 'synthetic disk image bytes\n' > "$work/state/$installer_archive"
cp "$work/state/$app_archive" "$work/input/Notary-Watch-App-9.8.7-universal-development.zip"
digest=$(shasum -a 256 "$work/input/Notary-Watch-App-9.8.7-universal-development.zip" | awk '{print $1}')
jq -n --arg digest "$digest" \
  '{schema:1,commit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",run_id:"123",version:"9.8.7",build_number:"42",architecture:"universal",archive:"Notary-Watch-App-9.8.7-universal-development.zip",archive_sha256:$digest}' > "$work/input/build-metadata.json"
release="$work/repository/scripts/release-macos.sh"
"$release" initialize "$work/input" "$work/state" "$work/outputs/release" > /dev/null
"$work/repository/scripts/notarize-stage.sh" submit app "$work/state/$app_archive" "$work/state" > /dev/null
"$work/repository/scripts/notarize-stage.sh" submit installer "$work/state/$installer_archive" "$work/state" > /dev/null
# Preserve a complete previous candidate, rather than an empty output directory.
printf 'previous complete ZIP\n' > "$work/outputs/release/Previous-App.zip"
printf 'previous complete DMG\n' > "$work/outputs/release/Previous-Installer.dmg"
printf '{"product":"Notary Watch","version":"9.8.6"}\n' > "$work/outputs/release/release-manifest.json"
(cd "$work/outputs/release" && shasum -a 256 Previous-App.zip Previous-Installer.dmg release-manifest.json > SHA256SUMS)
/usr/bin/ditto "$work/outputs/release" "$work/previous"
fail() { printf 'release output test failed: %s\n' "$*" >&2; exit 1; }
finalize() {
  local result=0
  "$release" finish-installer "$work/input" "$work/state" "$work/outputs/release" > "$work/finalize.log" 2>&1 || result=$?
  return "$result"
}
assert_preserved() {
  diff -qr "$work/previous" "$work/outputs/release" > /dev/null || fail 'Previous complete output changed after finalization failure.'
  [[ ! -e $work/outputs/release/$app_archive && ! -e $work/outputs/release/$installer_archive && ! -e $work/publication ]] || fail 'Failed candidate exposed final assets or reached publication.'
  for path in "$work/outputs/".notary-watch-release.*; do
    [[ ! -e $path ]] || fail 'Failed candidate left staging or backup output.'
  done
}
export TEST_REJECT_INSTALL=true
result=0; finalize || result=$?
[[ $result == 45 ]] || fail "Installed-copy rejection did not propagate its exact failure: $result"
grep -- '--type execute' "$work/assessments" >/dev/null || fail 'Rejection did not exercise installed-copy Gatekeeper assessment.'
[[ $(wc -l < "$work/mount-cleanup" | tr -d ' ') == 1 ]] || fail 'Rejected installer left its owned mount attached.'
assert_preserved
unset TEST_REJECT_INSTALL
export TEST_FAIL_FINAL_ZIP=true
result=0; finalize || result=$?
[[ $result == 46 && -f $work/packing ]] || fail "Final ZIP failure did not occur at the requested boundary: $result"
assert_preserved
unset TEST_FAIL_FINAL_ZIP
finalize
[[ -f $work/outputs/release/$app_archive && -f $work/outputs/release/$installer_archive && ! -e $work/outputs/release/Previous-App.zip ]] || fail 'Accepted complete candidate did not replace previous output.'
(cd "$work/outputs/release" && shasum -a 256 -c SHA256SUMS) > /dev/null
jq -e '.version == "9.8.7" and .commit == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .source_run_id == "123"' "$work/outputs/release/release-manifest.json" >/dev/null || fail 'Promoted manifest lost its candidate binding.'
[[ ! -e $work/publication ]] || fail 'Finalization attempted publication.'
printf 'Final release output packing, install-rejection, cleanup, preservation, and promotion witnesses passed.\n'
