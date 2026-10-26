#!/bin/bash
# Offline retirement witnesses. No Apple requests, real credentials or API writes.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-retirement-tests.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/bin"
export PATH="$work/bin:$PATH" TEST_RETIREMENT="$work"
export GH_REPO=fixture/repo BUILD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa BUILD_RUN_ID=100
cat > "$work/bin/gh" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ ${TEST_NETWORK_FAIL:-false} != true ]] || exit 42
if [[ $1 == api ]]; then
  case $* in
    *'/actions/runs/100') cat "$TEST_RETIREMENT/build.json" ;;
    *'/actions/runs/200') cat "$TEST_RETIREMENT/execution.json" ;;
    *'/workflows/distribution.yml/runs?'*) cat "$TEST_RETIREMENT/runs.json" ;;
    *'/releases?'*) cat "$TEST_RETIREMENT/release.json" ;;
    *'/releases/assets/777')
      if [[ ${TEST_CORRUPT_DOWNLOAD:-false} == true ]]; then printf '{}\n'; else cat "$TEST_RETIREMENT/remote-retired.json"; fi ;;
    *) exit 90 ;;
  esac
elif [[ $1 == release && $2 == upload ]]; then
  [[ $3 == notary-state-ci-100 && $5 == --repo && $6 == fixture/repo && $# == 6 ]] || exit 91
  [[ ! -f $TEST_RETIREMENT/remote-retired.json ]] || exit 92
  printf 'upload\n' >> "$TEST_RETIREMENT/writes"
  cp "$4" "$TEST_RETIREMENT/remote-retired.json"
  jq '.assets += [{id:777,name:"retired.json"}]' "$TEST_RETIREMENT/release.json" > "$TEST_RETIREMENT/changed.json"
  mv "$TEST_RETIREMENT/changed.json" "$TEST_RETIREMENT/release.json"
else exit 93; fi
STUB
chmod +x "$work/bin/gh"
fail() { printf 'Retirement regression failed: %s\n' "$*" >&2; exit 1; }
change() {
  local file=$1 filter=$2
  jq "$filter" "$file" > "$work/changed.json"
  mv "$work/changed.json" "$file"
}
reset() {
  rm -f "$work/remote-retired.json" "$work/writes"
  jq -n '{schema:1,commit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",ci_run_id:"100",execution_run_id:"200",reason:"notary_client_crash_no_uuid",retired_at:"2026-10-26T19:00:00Z"}' > "$work/record.json"
  jq -n '{path:".github/workflows/ci.yml",head_branch:"main",event:"push",status:"completed",conclusion:"success",head_sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repository:{full_name:"fixture/repo"},head_repository:{full_name:"fixture/repo"}}' > "$work/build.json"
  jq -n '{path:".github/workflows/distribution.yml",head_branch:"main",run_attempt:1,event:"workflow_run",status:"completed",conclusion:"failure",display_title:"Notary Watch distribution from CI 100",repository:{full_name:"fixture/repo"},head_repository:{full_name:"fixture/repo"}}' > "$work/execution.json"
  jq -n '{id:200,run_number:2,display_title:"Notary Watch distribution from CI 100"}' > "$work/runs.json"
  jq -n '{id:1,tag_name:"notary-state-ci-100",target_commitish:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",draft:true,prerelease:true,assets:[{id:123,name:"state-r200-s10.tar"},{id:124,name:"state-r200-s10.tar.sha256"}]}' > "$work/release.json"
}
run() { "$root/scripts/ci/retire-candidate.sh" "$work/record.json" > "$work/result.log" 2>&1; }
reject() {
  if run; then fail 'Unsafe retirement succeeded.'; fi
  [[ ! -f $work/writes ]] || fail 'Unsafe retirement wrote to GitHub.'
}
reset
run || { cat "$work/result.log"; fail 'Valid retirement failed.'; }
[[ $(wc -l < "$work/writes" | tr -d ' ') == 1 ]] || fail 'Valid retirement did not upload exactly once.'
run || { cat "$work/result.log"; fail 'Same retirement was not idempotent.'; }
[[ $(wc -l < "$work/writes" | tr -d ' ') == 1 ]] || fail 'Idempotent retirement rewrote immutable evidence.'
jq -e '.assets | length == 3 and any(.[]; .name == "state-r200-s10.tar") and any(.[]; .name == "state-r200-s10.tar.sha256")' "$work/release.json" >/dev/null || fail 'Retirement deleted previous state.'
rm "$work/writes"
change "$work/record.json" '.reason = "different_incident"'
reject
for filter in '.schema = 2' '.commit = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' '.ci_run_id = "101"' '.execution_run_id = "bad"' '.reason = "contains spaces"' '.reason = ""' '.retired_at = "2026-02-30T00:00:00Z"' '.retired_at = "2026-10-26"' '.secret = "must not upload"'; do
  reset
  change "$work/record.json" "$filter"
  reject
done
for filter in '.draft = false' '.prerelease = false' '.target_commitish = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'; do
  reset
  change "$work/release.json" "$filter"
  reject
done
reset
: > "$work/release.json"
reject
reset
cat >> "$work/release.json" <<'DUPLICATE'
{"id":2,"tag_name":"notary-state-ci-100","target_commitish":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","draft":true,"prerelease":true,"assets":[]}
DUPLICATE
reject
for filter in '.status = "in_progress"' '.conclusion = "success"' '.head_branch = "feature"' '.head_repository.full_name = "foreign/repo"' '.run_attempt = 2' '.display_title = "Notary Watch distribution from CI 101"'; do
  reset
  change "$work/execution.json" "$filter"
  reject
done
reset
cat >> "$work/runs.json" <<'LATER'
{"id":201,"run_number":3,"display_title":"Notary Watch distribution from CI 100"}
LATER
reject
reset
change "$work/build.json" '.event = "pull_request"'
reject
reset
export TEST_NETWORK_FAIL=true
reject
unset TEST_NETWORK_FAIL
reset
export TEST_CORRUPT_DOWNLOAD=true
if run; then fail 'Corrupt downloaded retirement passed verification.'; fi
[[ $(wc -l < "$work/writes" | tr -d ' ') == 1 ]] || fail 'Verification failure repeated an upload.'
unset TEST_CORRUPT_DOWNLOAD
run || fail 'An exact retained retirement could not recover after download failure.'
[[ $(wc -l < "$work/writes" | tr -d ' ') == 1 ]] || fail 'Download recovery overwrote retirement.'
printf 'Immutable retirement identity, failed-run provenance, preservation and no-overwrite witnesses passed.\n'
