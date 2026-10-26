#!/bin/bash
# Offline GitHub custody fixtures, without provider credentials or network calls.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-durable-tests.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin" "$work/remote" "$work/source" "$work/state"
export PATH="$work/bin:$PATH" TEST_CUSTODY="$work"
export GH_REPO=fixture/repo BUILD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa BUILD_RUN_ID=100 GITHUB_RUN_ID=200
# Never inherit the hosted job's environment file or custody pointer.
export GITHUB_ENV="$work/github-env"
unset NW_CUSTODY_RELEASE_ID
cat > "$work/bin/gh" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ ${TEST_NETWORK_FAIL:-false} != true ]] || exit 42
[[ $1 == api ]] || exit 90
shift
method=GET input= endpoint= tag= target=
while [[ $# -gt 0 ]]; do
  case $1 in
    --method) method=$2; shift ;;
    --input) input=$2; shift ;;
    -f|-F)
      case $2 in tag_name=*) tag=${2#*=} ;; target_commitish=*) target=${2#*=} ;; esac
      shift ;;
    -H|--jq) shift ;;
    --paginate) ;;
    *) endpoint=$1 ;;
  esac
  shift
done
remote=$TEST_CUSTODY/remote
case $method:$endpoint in
  GET:repos/fixture/repo/releases\?*)
    printf 'list\n' >> "$TEST_CUSTODY/reads"
    if [[ ${TEST_BAD_INVENTORY:-false} == true ]]; then printf '{'; exit 0; fi
    [[ ${TEST_OMIT_DRAFT:-false} != true ]] || exit 0
    [[ ! -f $remote/release.json ]] || cat "$remote/release.json" ;;
  POST:repos/fixture/repo/releases)
    printf 'create\n' >> "$TEST_CUSTODY/writes"
    [[ $target == "$BUILD_SHA" && $tag == notary-state-ci-100 ]] || exit 94
    jq -n --arg sha "$target" --arg tag "$tag" '{id:1,tag_name:$tag,target_commitish:$sha,draft:true,prerelease:true,assets:[]}' > "$remote/release.json"
    [[ ${TEST_RAW_CREATE_FAIL:-false} != true ]] || { printf 'gh: Resource not accessible by integration (HTTP 403)\n' >&2; exit 44; }
    if [[ ${TEST_BAD_CREATE_JSON:-false} == true ]]; then printf '{';
    else jq "${TEST_CREATE_MUTATION:-.}" "$remote/release.json"; fi ;;
  POST:https://uploads.github.com/repos/fixture/repo/releases/1/assets\?name=*)
    name=${endpoint##*=}
    [[ ! -e $remote/$name ]] || exit 93
    cp "$input" "$remote/$name"
    printf 'upload %s\n' "$name" >> "$TEST_CUSTODY/writes"
    jq --arg name "$name" --argjson size "$(wc -c < "$input" | tr -d ' ')" \
      '.assets += [{id:(([.assets[].id,9] | max) + 1),name:$name,state:"uploaded",size:$size}]' "$remote/release.json" > "$remote/next.json"
    mv "$remote/next.json" "$remote/release.json"
    jq ".assets[-1] | ${TEST_UPLOAD_MUTATION:-.}" "$remote/release.json" ;;
  GET:repos/fixture/repo/releases/assets/*)
    id=${endpoint##*/}
    printf 'download %s\n' "$id" >> "$TEST_CUSTODY/reads"
    name=$(jq -er --argjson id "$id" '.assets[] | select(.id == $id) | .name' "$remote/release.json")
    cat "$remote/$name" ;;
  GET:repos/fixture/repo/releases/1)
    printf 'get 1\n' >> "$TEST_CUSTODY/reads"
    if [[ ${TEST_REBIND_ASSET:-false} == true ]] && jq -e '.assets | length >= 2' "$remote/release.json" >/dev/null; then
      jq '.assets[0].id = 999' "$remote/release.json"
    else jq "${TEST_GET_MUTATION:-.}" "$remote/release.json"; fi ;;
  *) printf 'Unexpected fixture gh: %s %s\n' "$method" "$endpoint" >&2; exit 90 ;;
esac
STUB
chmod +x "$work/bin/gh"
fail() { printf 'durable custody test failed: %s\n' "$*" >&2; exit 1; }
run() { "$root/scripts/ci/durable-state.sh" "$@" > "$work/result.log" 2>&1; }
reject() { if run "$@"; then fail "accepted $*"; fi; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
app=Notary-Watch-App-1.2.3-universal-development.zip
dmg=Notary-Watch-Installer-1.2.3-universal-development.dmg
printf 'unsigned original app\n' > "$work/source/$app"
printf 'unsigned original image\n' > "$work/source/$dmg"
jq -n --arg sha "$BUILD_SHA" --arg digest "$(sha "$work/source/$app")" --arg app "$app" --arg dmg "$dmg" \
  '{schema:1,commit:$sha,run_id:"100",run_attempt:"1",version:"1.2.3",build_number:"7",architecture:"universal",archive:$app,dmg:$dmg,archive_sha256:$digest}' > "$work/source/build-metadata.json"
(cd "$work/source" && shasum -a 256 "$app" "$dmg") > "$work/source/SHA256SUMS"
jq -nS --arg sha "$BUILD_SHA" --arg digest "$(sha "$work/source/$app")" \
  '{schema:2,commit:$sha,run_id:"100",version:"1.2.3",build_number:"7",architecture:"universal",original_archive_sha256:$digest}' > "$work/state/origin.json"
export TEST_OMIT_DRAFT=true
run save-source "$work/source" || { cat "$work/result.log"; fail 'create succeeds while LIST omits the draft'; }
[[ $(grep -c '^list$' "$work/reads") == 1 ]] || fail 'Creation depended on rediscovery through LIST'
[[ $(cat "$GITHUB_ENV") == NW_CUSTODY_RELEASE_ID=1 ]] || fail 'Verified source did not export its release pointer'
export NW_CUSTODY_RELEASE_ID=1
run save "$work/state" 00 || { cat "$work/result.log"; fail 'next step uses verified exact ID despite omitted LIST'; }
[[ $(grep -c '^list$' "$work/reads") == 1 ]] || fail 'Cached pointer used LIST'
unset TEST_OMIT_DRAFT NW_CUSTODY_RELEASE_ID
run restore-source "$work/source-restored" || { cat "$work/result.log"; fail 'source restore'; }
diff -qr "$work/source" "$work/source-restored" >/dev/null || fail 'source bytes changed'
export BUILD_ATTEMPT=2
reject save-source "$work/source"
reject restore-source "$work/wrong-ci-attempt"
unset BUILD_ATTEMPT
writes=$(wc -l < "$work/writes")
touch "$work/source/$app"
chmod 644 "$work/source/$app"
run save-source "$work/source" || { cat "$work/result.log"; fail 'source custody idempotence'; }
[[ $(wc -l < "$work/writes") == "$writes" ]] || fail 'repeat save wrote existing assets'
run save "$work/state" 00 || { cat "$work/result.log"; fail 'initial state custody'; }
run restore 200 00 "$work/state-restored" || { cat "$work/result.log"; fail 'state restore'; }
diff -qr "$work/state" "$work/state-restored" >/dev/null || fail 'state bytes changed'
reject restore 200 05 "$work/missing"
[[ ! -e $work/missing ]] || fail 'missing restore left output'
reject restore-source "$work/source-restored"
ln -s origin.json "$work/state/app.status.json"
reject save "$work/state" 05
rm "$work/state/app.status.json"
printf 'private credential\n' > "$work/state/private-secret"
reject save "$work/state" 05
rm "$work/state/private-secret"
export BUILD_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
reject restore 200 00 "$work/wrong-source"
reject save-source "$work/source"
export BUILD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
jq '.draft=false' "$work/remote/release.json" > "$work/remote/next.json"
mv "$work/remote/next.json" "$work/remote/release.json"
reject restore 200 00 "$work/published"
jq '.draft=true' "$work/remote/release.json" > "$work/remote/next.json"
mv "$work/remote/next.json" "$work/remote/release.json"
cp "$work/remote/state-r200-s00.tar" "$work/valid.tar"
printf corrupt > "$work/remote/state-r200-s00.tar"
reject restore 200 00 "$work/corrupt"
cp "$work/valid.tar" "$work/remote/state-r200-s00.tar"
printf '%064d  state-r200-s00.tar\n' 0 > "$work/remote/state-r200-s00.tar.sha256"
reject restore 200 00 "$work/wrong-digest"
printf '%s  state-r200-s00.tar\n' "$(sha "$work/remote/state-r200-s00.tar")" > "$work/remote/state-r200-s00.tar.sha256"
mkdir "$work/bad"
ln -s /tmp "$work/bad/origin.json"
(cd "$work/bad" && COPYFILE_DISABLE=1 tar -cf "$TEST_CUSTODY/remote/state-r200-s00.tar" ./origin.json)
printf '%s  state-r200-s00.tar\n' "$(sha "$work/remote/state-r200-s00.tar")" > "$work/remote/state-r200-s00.tar.sha256"
reject restore 200 00 "$work/link"
[[ ! -e $work/link ]] || fail 'unsafe extraction left output'
rm "$work/bad/origin.json"
cp "$work/state/origin.json" "$work/bad/origin.json"
(cd "$work/bad" && COPYFILE_DISABLE=1 tar -cf "$TEST_CUSTODY/remote/state-r200-s00.tar" ./origin.json ./origin.json)
printf '%s  state-r200-s00.tar\n' "$(sha "$work/remote/state-r200-s00.tar")" > "$work/remote/state-r200-s00.tar.sha256"
reject restore 200 00 "$work/duplicate-entry"
(cd "$work/bad" && COPYFILE_DISABLE=1 tar -cf "$TEST_CUSTODY/remote/state-r200-s00.tar" -P "$TEST_CUSTODY/bad/origin.json")
printf '%s  state-r200-s00.tar\n' "$(sha "$work/remote/state-r200-s00.tar")" > "$work/remote/state-r200-s00.tar.sha256"
reject restore 200 00 "$work/absolute-entry"
cp "$work/valid.tar" "$work/remote/state-r200-s00.tar"
printf '%s  state-r200-s00.tar\n' "$(sha "$work/remote/state-r200-s00.tar")" > "$work/remote/state-r200-s00.tar.sha256"
# An interrupted pair upload is recoverable only when its archive is identical.
rm "$work/remote/state-r200-s00.tar.sha256"
jq 'del(.assets[] | select(.name == "state-r200-s00.tar.sha256"))' "$work/remote/release.json" > "$work/remote/next.json"
mv "$work/remote/next.json" "$work/remote/release.json"
reject restore 200 00 "$work/incomplete-pair"
run save "$work/state" 00 || { cat "$work/result.log"; fail 'same-byte pair repair'; }
printf changed >> "$work/remote/state-r200-s00.tar"
reject save "$work/state" 00
mkdir "$work/final"
final_app=Notary-Watch-App-1.2.3-build.7-100-universal.zip
final_dmg=Notary-Watch-Installer-1.2.3-build.7-100-universal.dmg
# These are custody fixtures only, without signatures or Apple acceptance proof.
printf 'fixture final app\n' > "$work/final/$final_app"
printf 'fixture final image\n' > "$work/final/$final_dmg"
jq -n --arg sha "$BUILD_SHA" \
  '{product:"Notary Watch",commit:$sha,source_run_id:"100",build_number:"7",version:"1.2.3",architecture:"universal",team_id:"AAAAAAAAAA",
    notarization:{app:"11111111-1111-1111-1111-111111111111",installer:"22222222-2222-2222-2222-222222222222"},
    submitted_sha256:{app:("a" * 64),installer:("b" * 64)}}' > "$work/final/release-manifest.json"
(cd "$work/final" && shasum -a 256 "$final_app" "$final_dmg" release-manifest.json) > "$work/final/SHA256SUMS"
run save-final "$work/final" || { cat "$work/result.log"; fail 'initial final custody'; }
writes=$(wc -l < "$work/writes")
run save-final "$work/final" || { cat "$work/result.log"; fail 'final custody idempotence'; }
[[ $(wc -l < "$work/writes") == "$writes" ]] || fail 'repeat final save wrote existing assets'
run restore-final "$work/final-restored" || { cat "$work/result.log"; fail 'exact final restore'; }
diff -qr "$work/final" "$work/final-restored" >/dev/null || fail 'final bytes changed'
export BUILD_NUMBER=8
reject restore-final "$work/final-wrong-build"
reject save-final "$work/final"
unset BUILD_NUMBER
cp "$work/final/release-manifest.json" "$work/good-final-manifest"
jq '.notarization.installer = .notarization.app' "$work/good-final-manifest" > "$work/final/release-manifest.json"
(cd "$work/final" && shasum -a 256 "$final_app" "$final_dmg" release-manifest.json) > "$work/final/SHA256SUMS"
reject save-final "$work/final"
cp "$work/good-final-manifest" "$work/final/release-manifest.json"
(cd "$work/final" && shasum -a 256 "$final_app" "$final_dmg" release-manifest.json) > "$work/final/SHA256SUMS"
printf changed >> "$work/final/$final_dmg"
reject save-final "$work/final"
printf changed >> "$work/remote/final.tar"
reject restore-final "$work/final-corrupt"
[[ ! -e $work/final-corrupt ]] || fail 'failed final restoration exposed a partial candidate'
# Cached pointers are never authority and never fall back to CREATE.
writes=$(wc -l < "$work/writes")
for pointer in 2 bad; do
  export NW_CUSTODY_RELEASE_ID=$pointer
  reject save-source "$work/source"
done
export NW_CUSTODY_RELEASE_ID=1
for mutation in '.id=2' '.target_commitish="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' '.tag_name="other"' '.draft=false' '.prerelease=false' '.assets[0].state="starter"'; do
  export TEST_GET_MUTATION=$mutation
  reject restore-source "$work/invalid-pointer-binding"
done
unset TEST_GET_MUTATION NW_CUSTODY_RELEASE_ID
[[ $(wc -l < "$work/writes") == "$writes" ]] || fail 'Invalid pointers caused writes'
export TEST_BAD_INVENTORY=true
reject save-source "$work/source"
[[ $(wc -l < "$work/writes") == "$writes" ]] || fail 'Malformed inventory caused writes'
unset TEST_BAD_INVENTORY
# Isolate create failures from retained valid custody.
mv "$work/remote" "$work/saved-remote"
cp "$GITHUB_ENV" "$work/verified-env"
for mutation in '.id=0' '.id=2' '.id=1.5' '.id="1"' '.target_commitish="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' '.tag_name="other"' '.draft=false' '.prerelease=false'; do
  mkdir "$work/remote"
  : > "$work/writes"
  export TEST_CREATE_MUTATION=$mutation
  reject save-source "$work/source"
  [[ $(cat "$work/writes") == create ]] || fail 'Invalid create identity caused uploads or duplicate POST'
  rm -rf "$work/remote"
done
unset TEST_CREATE_MUTATION
for fault in TEST_RAW_CREATE_FAIL TEST_BAD_CREATE_JSON; do
  mkdir "$work/remote"
  : > "$work/writes"
  export "${fault}=true"
  reject save-source "$work/source"
  [[ $(cat "$work/writes") == create ]] || fail 'Failed create was retried'
  if [[ $fault == TEST_RAW_CREATE_FAIL ]]; then
    grep -F 'Resource not accessible by integration (HTTP 403)' "$work/result.log" >/dev/null || fail 'Provider rejection was hidden'
  fi
  unset "$fault"
  rm -rf "$work/remote"
done
for mutation in '.id=999' '.id=0' '.name="wrong"' '.state="starter"' '.size=0'; do
  mkdir "$work/remote"
  export TEST_UPLOAD_MUTATION=$mutation
  reject save-source "$work/source"
  rm -rf "$work/remote"
done
unset TEST_UPLOAD_MUTATION
mkdir "$work/remote"
export TEST_REBIND_ASSET=true
reject save-source "$work/source"
unset TEST_REBIND_ASSET
rm -rf "$work/remote"
cmp -s "$work/verified-env" "$GITHUB_ENV" || fail 'Unverified custody exported a pointer'
mv "$work/saved-remote" "$work/remote"
export TEST_NETWORK_FAIL=true
reject save "$work/state" 05
reject restore-source "$work/network"
unset TEST_NETWORK_FAIL
printf 'Durable source/checkpoint/final identity, immutable custody and hostile extraction witnesses passed.\n'
