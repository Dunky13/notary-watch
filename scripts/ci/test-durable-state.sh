#!/bin/bash
# Offline GitHub custody fixtures, without provider credentials or network calls.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-durable-tests.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin" "$work/remote" "$work/source" "$work/state"
export PATH="$work/bin:$PATH" TEST_CUSTODY="$work"
export GH_REPO=fixture/repo BUILD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa BUILD_RUN_ID=100 GITHUB_RUN_ID=200
cat > "$work/bin/gh" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ ${TEST_NETWORK_FAIL:-false} != true ]] || exit 42
if [[ $1 == api && $* == *'/releases?per_page=100'* ]]; then
  [[ ! -f $TEST_CUSTODY/remote/release.json ]] || cat "$TEST_CUSTODY/remote/release.json"
elif [[ $1 == release && $2 == create ]]; then
  printf '%s\n' create >> "$TEST_CUSTODY/writes"
  jq -n --arg sha "$BUILD_SHA" --arg tag "$3" '{id:1,tag_name:$tag,target_commitish:$sha,draft:true,prerelease:true,assets:[]}' > "$TEST_CUSTODY/remote/release.json"
elif [[ $1 == release && $2 == upload ]]; then
  name=$(basename "$4")
  [[ ! -e $TEST_CUSTODY/remote/$name ]] || exit 93
  cp "$4" "$TEST_CUSTODY/remote/$name"
  printf 'upload %s\n' "$name" >> "$TEST_CUSTODY/writes"
  jq --arg name "$name" '.assets += [{id:((.assets | length) + 10),name:$name}]' "$TEST_CUSTODY/remote/release.json" > "$TEST_CUSTODY/remote/next.json"
  mv "$TEST_CUSTODY/remote/next.json" "$TEST_CUSTODY/remote/release.json"
elif [[ $1 == api && $* == *'/releases/assets/'* ]]; then
  id=${!#}
  id=${id##*/}
  name=$(jq -er --argjson id "$id" '.assets[] | select(.id == $id) | .name' "$TEST_CUSTODY/remote/release.json")
  cat "$TEST_CUSTODY/remote/$name"
else
  printf 'Unexpected fixture gh: %s\n' "$*" >&2
  exit 90
fi
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
run save-source "$work/source" || { cat "$work/result.log"; fail 'initial source custody'; }
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
export TEST_NETWORK_FAIL=true
reject save "$work/state" 05
reject restore-source "$work/network"
unset TEST_NETWORK_FAIL
printf 'Durable source/checkpoint/final identity, immutable custody and hostile extraction witnesses passed.\n'
