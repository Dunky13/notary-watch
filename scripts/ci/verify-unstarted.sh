#!/bin/bash
# Read-only proof across the complete retained candidate lineage. A later empty
# run cannot erase an earlier signing/upload attempt or substitute for receipts.
set -euo pipefail
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/../lib/macos.sh"
[[ $# == 3 && -f $1 && $2 =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && $3 =~ ^[1-9][0-9]*$ ]] || nw_fail 'Usage: verify-unstarted.sh candidate-runs.json repository original-CI-run'
runs=$1 repo=$2 build=$3
jq -e --arg build "$build" 'type == "array" and length > 0
  and all(.[]; (.id | type == "number" and . > 0 and . == floor)
    and (.run_number | type == "number" and . > 0 and . == floor)
    and .display_title == ("Notary Watch distribution from CI " + $build))
  and ([.[].id] | length == (unique | length))
  and ([.[].run_number] | length == (unique | length))' "$runs" >/dev/null || nw_fail 'No unique candidate execution lineage is available.'
work=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-unstarted.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
while IFS=$'\t' read -r id number; do
  gh api "repos/$repo/actions/runs/$id" > "$work/run.json"
  jq -e --arg repo "$repo" --arg build "$build" --argjson id "$id" --argjson number "$number" \
    '.id == $id and .run_number == $number and .run_attempt == 1
     and .path == ".github/workflows/distribution.yml" and .head_branch == "main"
     and .repository.full_name == $repo and .head_repository.full_name == $repo
     and (.event == "workflow_run" or .event == "workflow_dispatch")
     and .status == "completed" and (.conclusion == "failure" or .conclusion == "timed_out")
     and .display_title == ("Notary Watch distribution from CI " + $build)' \
    "$work/run.json" >/dev/null || nw_fail 'Execution provenance does not prove a failed unstarted candidate.'
  gh api --paginate "repos/$repo/actions/runs/$id/attempts/1/jobs?per_page=100" --jq '.jobs[]' | jq -s '.' > "$work/jobs.json"
  jq -e -f "$NW_ROOT/scripts/lib/unstarted-jobs.jq" "$work/jobs.json" >/dev/null || nw_fail 'A prior job may have executed; preserve its checkpoint and submission reservation.'
done < <(jq -r '.[] | [.id,.run_number] | @tsv' "$runs")
printf 'Verified all retained candidate executions had no runner, steps or signing.\n'
