#!/bin/bash
set -euo pipefail
[[ $# == 1 && -f $1/Contents/MacOS/NotaryWatch ]] || exit 1
work=$(mktemp -d)
child_pid=
cleanup() {
  local result=$?
  if [[ -n $child_pid ]]; then kill -TERM "$child_pid" 2>/dev/null || true; wait "$child_pid" 2>/dev/null || true; fi
  rm -rf -- "$work"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Sample mode makes no Apple history request and needs no credentials.
"$1/Contents/MacOS/NotaryWatch" --demo > "$work/launch.log" 2>&1 &
child_pid=$!
sleep 3
if ! kill -0 "$child_pid" 2>/dev/null; then cat "$work/launch.log" >&2; exit 1; fi
printf 'Packaged app remained running in sample mode.\n'
