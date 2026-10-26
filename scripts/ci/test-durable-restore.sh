#!/bin/bash
# Exercise the real read-only custody path with the host's native tar reader.
# Linux control jobs never create distribution/signing archives or run Apple code.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-restore-tests.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/state" "$work/bin"
export GH_REPO=fixture/repo BUILD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa BUILD_RUN_ID=100 TEST_RESTORE_ROOT="$work" PATH="$work/bin:$PATH"
unset NW_CUSTODY_RELEASE_ID
export GITHUB_ENV="$work/github-env"
name=Notary-Watch-App-9.8.7-build.7-100-universal.zip
printf 'Retained synthetic signed upload bytes\n' > "$work/state/$name"
digest=$(shasum -a 256 "$work/state/$name" | awk '{print $1}')
jq -nS --arg sha "$BUILD_SHA" --arg digest "$digest" '{schema:2,commit:$sha,run_id:"100",version:"9.8.7",build_number:"7",architecture:"universal",original_archive_sha256:$digest}' > "$work/state/origin.json"
jq -n --arg sha "$BUILD_SHA" --arg digest "$digest" --arg name "$name" '{schema:2,stage:"app",archive:$name,sha256:$digest,commit:$sha,version:"9.8.7",build:"7",architecture:"universal",ci_run_id:"100"}' > "$work/state/app.intent.json"
jq '. + {id:"12345678-1234-1234-1234-123456789abc"}' "$work/state/app.intent.json" > "$work/state/app.submission.json"
printf '%s\n' "$digest" > "$work/state/app.archive.sha256"
"$root/scripts/checkpoint-macos.sh" "$work/state" "$work/safe" > /dev/null
(cd "$work/safe" && COPYFILE_DISABLE=1 tar --format ustar -cf "$work/state-r200-s20.tar" ./*)
(cd "$work" && shasum -a 256 state-r200-s20.tar > state-r200-s20.tar.sha256)
cat > "$work/bin/gh" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ $1 == api ]] || exit 90
release() {
  jq -n --arg sha "$BUILD_SHA" --argjson archive_size "$(wc -c < "$TEST_RESTORE_ROOT/state-r200-s20.tar" | tr -d ' ')" \
    --argjson checksum_size "$(wc -c < "$TEST_RESTORE_ROOT/state-r200-s20.tar.sha256" | tr -d ' ')" \
    '{id:10,tag_name:"notary-state-ci-100",draft:true,prerelease:true,target_commitish:$sha,assets:[{id:111,name:"state-r200-s20.tar",state:"uploaded",size:$archive_size},{id:112,name:"state-r200-s20.tar.sha256",state:"uploaded",size:$checksum_size}]}'
}
case $* in
  *'/releases?'*|*'/releases/10') release ;;
  *'/releases/assets/111') cat "$TEST_RESTORE_ROOT/state-r200-s20.tar" ;;
  *'/releases/assets/112') cat "$TEST_RESTORE_ROOT/state-r200-s20.tar.sha256" ;;
  *) exit 91 ;;
esac
STUB
chmod +x "$work/bin/gh"
"$root/scripts/ci/durable-state.sh" restore 200 20 "$work/restored" > /dev/null
diff -qr "$work/safe" "$work/restored" > /dev/null
printf 'changed remote bytes\n' >> "$work/state-r200-s20.tar"
if "$root/scripts/ci/durable-state.sh" restore 200 20 "$work/corrupt" > /dev/null 2>&1; then
  printf 'Corrupt custody passed the native tar reader.\n' >&2; exit 1
fi
[[ ! -e $work/corrupt ]] || exit 1
printf 'Native tar custody restore preserved bound UUID/bytes and rejected corruption.\n'
