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
[[ $1 == api ]] || exit 90
shift
method=GET input= endpoint= tag= target= latest=
while [[ $# -gt 0 ]]; do
  case $1 in
    --method) method=$2; shift ;;
    --input) input=$2; shift ;;
    -f|-F)
      case $2 in tag_name=*) tag=${2#*=} ;; target_commitish=*) target=${2#*=} ;; make_latest=*) latest=${2#*=} ;; esac
      shift ;;
    -H|--jq) shift ;;
    --paginate) ;;
    *) endpoint=$1 ;;
  esac
  shift
done
case $method:$endpoint in
  GET:repos/fixture/repo/git/ref/tags/*)
    if [[ ${TEST_WRONG_TAG:-false} == true || -f $TEST_REMOTE/published ]]; then printf '{}\n';
    else printf 'gh: Not Found (HTTP 404)\n' >&2; exit 1; fi ;;
  GET:repos/fixture/repo/commits/*)
    sha=$BUILD_SHA
    [[ ${TEST_WRONG_TAG:-false} != true ]] || sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    jq -n --arg sha "$sha" '{sha:$sha}' ;;
  GET:repos/fixture/repo/releases\?*)
    [[ ${TEST_API_FAIL:-false} != true ]] || exit 33
    printf 'list\n' >> "$TEST_REMOTE/reads"
    if [[ ${TEST_BAD_INVENTORY:-false} == true ]]; then printf '{'; exit 0; fi
    if [[ ${TEST_NEWER_STABLE:-false} == true ]]; then printf '{"tag_name":"v10.0.0","draft":false,"prerelease":false}\n'; fi
    [[ ${TEST_OMIT_DRAFT:-false} != true ]] || exit 0
    [[ ! -f $TEST_REMOTE/release.json ]] || cat "$TEST_REMOTE/release.json" ;;
  POST:repos/fixture/repo/releases)
    printf 'create\n' >> "$TEST_REMOTE/calls"
    [[ $tag == v9.8.7 && $target == "$BUILD_SHA" ]] || exit 94
    jq -n --arg sha "$target" '{id:1,tag_name:"v9.8.7",target_commitish:$sha,draft:true,prerelease:false,assets:[]}' > "$TEST_REMOTE/release.json"
    [[ ${TEST_RAW_CREATE_FAIL:-false} != true ]] || { printf 'gh: Resource not accessible by integration (HTTP 403)\n' >&2; exit 44; }
    if [[ ${TEST_BAD_CREATE_JSON:-false} == true ]]; then printf '{';
    else jq "${TEST_CREATE_MUTATION:-.}" "$TEST_REMOTE/release.json"; fi ;;
  POST:https://uploads.github.com/repos/fixture/repo/releases/1/assets\?name=*)
    name=${endpoint##*=}
    [[ ${TEST_UPLOAD_FAIL_NAME:-} != "$name" ]] || exit 45
    [[ ! -e $TEST_REMOTE/assets/$name ]] || exit 93
    cp "$input" "$TEST_REMOTE/assets/$name"
    printf 'upload\n' >> "$TEST_REMOTE/calls"
    jq --arg name "$name" --argjson size "$(wc -c < "$input" | tr -d ' ')" \
      '.assets += [{id:(([.assets[].id,9] | max) + 1),name:$name,state:"uploaded",size:$size}]' "$TEST_REMOTE/release.json" > "$TEST_REMOTE/next.json"
    mv "$TEST_REMOTE/next.json" "$TEST_REMOTE/release.json"
    jq ".assets[-1] | ${TEST_UPLOAD_MUTATION:-.}" "$TEST_REMOTE/release.json" ;;
  GET:repos/fixture/repo/releases/assets/*)
    id=${endpoint##*/}
    printf 'download %s\n' "$id" >> "$TEST_REMOTE/reads"
    name=$(jq -er --argjson id "$id" '.assets[] | select(.id == $id) | .name' "$TEST_REMOTE/release.json")
    cat "$TEST_REMOTE/assets/$name"
    if [[ ${TEST_CORRUPT_DOWNLOAD:-false} == true ]]; then printf 'corrupt\n'; fi ;;
  GET:repos/fixture/repo/releases/1)
    printf 'get 1\n' >> "$TEST_REMOTE/reads"
    if [[ ${TEST_REBIND_ASSET:-false} == true ]] && jq -e '.assets | length == 4' "$TEST_REMOTE/release.json" >/dev/null; then
      jq '.assets[0].id=999' "$TEST_REMOTE/release.json"
    else jq "${TEST_GET_MUTATION:-.}" "$TEST_REMOTE/release.json"; fi ;;
  PATCH:repos/fixture/repo/releases/1)
    printf 'edit\n' >> "$TEST_REMOTE/calls"
    printf '%s\n' "$latest" > "$TEST_REMOTE/edit-arguments"
    jq '.draft=false' "$TEST_REMOTE/release.json" > "$TEST_REMOTE/next.json"
    mv "$TEST_REMOTE/next.json" "$TEST_REMOTE/release.json"
    : > "$TEST_REMOTE/published"
    cat "$TEST_REMOTE/release.json" ;;
  *) printf 'Unexpected fixture gh: %s %s\n' "$method" "$endpoint" >&2; exit 91 ;;
esac
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
export TEST_OMIT_DRAFT=true
publish || { cat "$work/result.log"; fail 'create succeeds while LIST omits the draft'; }
[[ $(grep -c '^list$' "$TEST_REMOTE/reads") == 2 ]] || fail 'Fresh release depended on LIST rediscovery'
unset TEST_OMIT_DRAFT
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
export TEST_BAD_INVENTORY=true
cp "$TEST_REMOTE/calls" "$work/before-inventory"
expect_failure 'Malformed release inventory was treated as absence'
cmp -s "$TEST_REMOTE/calls" "$work/before-inventory" || fail 'Malformed inventory caused writes'
unset TEST_BAD_INVENTORY
rm "$TEST_REMOTE/release.json" "$TEST_REMOTE/published" "$TEST_REMOTE/calls" "$TEST_REMOTE/assets/"*
export TEST_NEWER_STABLE=true
publish
grep -Fx -- 'false' "$TEST_REMOTE/edit-arguments" >/dev/null || fail 'An older recovered candidate moved latest backwards.'
unset TEST_NEWER_STABLE
# Existing source/state/asset bindings must fail without any mutations.
cp "$TEST_REMOTE/calls" "$work/before-invalid"
for mutation in '.id=2' '.target_commitish="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' '.tag_name="other"' '.prerelease=true' '.draft=null' '.assets[0].state="starter"' '.assets[1].id=.assets[0].id'; do
  export TEST_GET_MUTATION=$mutation
  expect_failure 'An invalid direct-GET binding passed publication'
done
unset TEST_GET_MUTATION
cmp -s "$TEST_REMOTE/calls" "$work/before-invalid" || fail 'Invalid existing binding caused writes'
# Missing published assets remain immutable.
cp "$TEST_REMOTE/release.json" "$work/complete.json"
jq 'del(.assets[-1])' "$work/complete.json" > "$TEST_REMOTE/release.json"
expect_failure 'An incomplete published release was mutated'
cmp -s "$TEST_REMOTE/calls" "$work/before-invalid" || fail 'Published release was repaired in place'
cp "$work/complete.json" "$TEST_REMOTE/release.json"
# Isolate failure cases, asserting one CREATE and no promotion.
reset_remote() {
  rm -rf "$TEST_REMOTE"
  mkdir -p "$TEST_REMOTE/assets"
}
# Retry fills only the missing assets of a partially uploaded draft.
reset_remote
export TEST_UPLOAD_FAIL_NAME="Notary-Watch-Installer-$suffix.dmg"
expect_failure 'Interrupted upload unexpectedly succeeded'
[[ $(grep -c '^upload$' "$TEST_REMOTE/calls") == 1 && ! -f $TEST_REMOTE/published ]] || fail 'Interrupted upload was promoted'
unset TEST_UPLOAD_FAIL_NAME
publish
[[ $(grep -c '^create$' "$TEST_REMOTE/calls") == 1 && $(grep -c '^upload$' "$TEST_REMOTE/calls") == 4 ]] || fail 'Partial retry recreated or overwrote assets'
for mutation in '.id=0' '.id=2' '.id=1.5' '.id="1"' '.tag_name="other"' '.target_commitish="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' '.draft=false' '.prerelease=true'; do
  reset_remote
  export TEST_CREATE_MUTATION=$mutation
  expect_failure 'Invalid create binding was accepted'
  [[ $(cat "$TEST_REMOTE/calls") == create ]] || fail 'Invalid create caused upload or duplicate POST'
done
unset TEST_CREATE_MUTATION
for fault in TEST_RAW_CREATE_FAIL TEST_BAD_CREATE_JSON; do
  reset_remote
  export "${fault}=true"
  expect_failure 'Failed raw create was accepted'
  [[ $(cat "$TEST_REMOTE/calls") == create ]] || fail 'Failed create was retried'
  if [[ $fault == TEST_RAW_CREATE_FAIL ]]; then
    grep -F 'Resource not accessible by integration (HTTP 403)' "$work/result.log" >/dev/null || fail 'Provider rejection was hidden'
  fi
  unset "$fault"
done
for mutation in '.id=999' '.id=0' '.name="wrong"' '.state="starter"' '.size=0'; do
  reset_remote
  export TEST_UPLOAD_MUTATION=$mutation
  expect_failure 'Wrong upload identity reached publication'
  [[ ! -f $TEST_REMOTE/published ]] || fail 'Invalid upload was promoted'
done
unset TEST_UPLOAD_MUTATION
reset_remote
export TEST_REBIND_ASSET=true
expect_failure 'Changed remote asset ID reached publication'
[[ ! -f $TEST_REMOTE/published ]] || fail 'Changed asset ID was promoted'
unset TEST_REBIND_ASSET
printf 'changed\n' >> "$work/assets/Notary-Watch-App-$suffix.zip"
expect_failure 'Changed final assets passed checksum validation.'
printf 'Production publication recovery and promotion witnesses passed.\n'
