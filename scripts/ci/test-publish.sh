#!/bin/bash
# Offline GitHub witnesses: no network, credentials, or public release mutations.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-publication-tests.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin" "$work/assets" "$work/remote" "$work/remote/assets"
export TEST_REMOTE="$work/remote" PATH="$work/bin:$PATH"
export GH_REPO=fixture/repo BUILD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa BUILD_NUMBER=7 SOURCE_RUN=100
cat > "$work/bin/gh" <<'STUB'
#!/bin/bash
set -euo pipefail
if [[ $1 == api ]]; then
  case $* in
    *'/git/ref/tags/'*)
      if [[ ${TEST_WRONG_TAG:-false} == true || -f $TEST_REMOTE/published ]]; then printf '{}\n';
      else printf 'gh: Not Found (HTTP 404)\n' >&2; exit 1; fi ;;
    *'/commits/'*)
      sha=$BUILD_SHA
      [[ ${TEST_WRONG_TAG:-false} != true ]] || sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      jq -n --arg sha "$sha" '{sha:$sha}' ;;
    *'/releases?'*)
      [[ ${TEST_API_FAIL:-false} != true ]] || exit 33
      [[ ! -f $TEST_REMOTE/release.json ]] || cat "$TEST_REMOTE/release.json" ;;
    *) exit 91 ;;
  esac
elif [[ $1 == release ]]; then
  operation=$2; shift 2
  printf '%s\n' "$operation" >> "$TEST_REMOTE/calls"
  case $operation in
    create)
      jq -n --arg sha "$BUILD_SHA" '{tag_name:"v9.8.7",target_commitish:$sha,draft:true,prerelease:false,assets:[]}' > "$TEST_REMOTE/release.json" ;;
    upload)
      path=$2
      name=$(basename "$path")
      cp "$path" "$TEST_REMOTE/assets/$name"
      jq --arg name "$name" '.assets += [{name:$name}]' "$TEST_REMOTE/release.json" > "$TEST_REMOTE/next.json"
      mv "$TEST_REMOTE/next.json" "$TEST_REMOTE/release.json" ;;
    download)
      destination=
      while [[ $# -gt 0 ]]; do if [[ $1 == --dir ]]; then destination=$2; shift; fi; shift; done
      [[ -n $destination ]] || exit 92
      cp "$TEST_REMOTE/assets/"* "$destination/"
      if [[ ${TEST_CORRUPT_DOWNLOAD:-false} == true ]]; then printf 'corrupt\n' >> "$destination/release-manifest.json"; fi ;;
    edit)
      jq '.draft = false' "$TEST_REMOTE/release.json" > "$TEST_REMOTE/next.json"
      mv "$TEST_REMOTE/next.json" "$TEST_REMOTE/release.json"
      : > "$TEST_REMOTE/published" ;;
    *) exit 93 ;;
  esac
else exit 94; fi
STUB
chmod +x "$work/bin/gh"
suffix=9.8.7-build.7-100-universal
printf 'signed app fixture\n' > "$work/assets/Notary-Watch-App-$suffix.zip"
printf 'signed image fixture\n' > "$work/assets/Notary-Watch-Installer-$suffix.dmg"
jq -n --arg sha "$BUILD_SHA" \
  '{product:"Notary Watch",version:"9.8.7",commit:$sha,source_run_id:"100",build_number:"7",architecture:"universal",notarization:{app:"12345678-1234-1234-1234-123456789abc",installer:"12345678-1234-1234-1234-123456789abc"}}' > "$work/assets/release-manifest.json"
(cd "$work/assets" && shasum -a 256 "Notary-Watch-App-$suffix.zip" "Notary-Watch-Installer-$suffix.dmg" release-manifest.json > SHA256SUMS)
fail() { printf 'publication test failed: %s\n' "$*" >&2; exit 1; }
publish() { "$root/scripts/ci/publish-release.sh" "$work/assets" > "$work/result.log" 2>&1; }
expect_failure() { if (publish); then fail "$1"; fi; }
publish
[[ $(grep -c '^upload$' "$TEST_REMOTE/calls") == 4 && $(grep -c '^edit$' "$TEST_REMOTE/calls") == 1 ]] || fail 'Fresh candidate did not publish exactly four verified assets.'
cp "$TEST_REMOTE/calls" "$work/first-calls"
publish
[[ $(grep -c '^upload$' "$TEST_REMOTE/calls") == 4 && $(grep -c '^edit$' "$TEST_REMOTE/calls") == 1 ]] || fail 'Published candidate was mutated on retry.'
rm "$TEST_REMOTE/release.json" "$TEST_REMOTE/published" "$TEST_REMOTE/calls" "$TEST_REMOTE/assets/"*
export TEST_CORRUPT_DOWNLOAD=true
expect_failure 'A mismatched remote asset was published.'
[[ ! -f $TEST_REMOTE/published ]] || fail 'Asset mismatch passed promotion.'
jq -e '.draft == true' "$TEST_REMOTE/release.json" >/dev/null || fail 'Failed candidate was not retained as a draft.'
unset TEST_CORRUPT_DOWNLOAD
publish
[[ $(grep -c '^upload$' "$TEST_REMOTE/calls") == 4 ]] || fail 'Draft retry overwrote already uploaded assets.'
export TEST_WRONG_TAG=true
expect_failure 'An existing version tag was moved to different source.'
unset TEST_WRONG_TAG
export TEST_API_FAIL=true
expect_failure 'A failed release inventory was treated as an absent release.'
unset TEST_API_FAIL
printf 'changed\n' >> "$work/assets/Notary-Watch-App-$suffix.zip"
expect_failure 'Changed final assets passed checksum validation.'
printf 'Production publication recovery and promotion witnesses passed.\n'
