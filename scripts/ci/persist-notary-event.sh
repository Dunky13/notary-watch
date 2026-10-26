#!/bin/bash
# Called synchronously by the locked submitter. No private client files leave state.
set -euo pipefail
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/../lib/macos.sh"
[[ $# == 3 ]] || nw_fail 'Usage: persist-notary-event.sh state app|installer intent|receipt'
state=$1 stage=$2 event=$3
case "$stage:$event" in
  app:intent) slot=11 ;;
  app:receipt) slot=12 ;;
  installer:intent) slot=31 ;;
  installer:receipt) slot=32 ;;
  *) nw_fail 'Unknown durable notarization event.' ;;
esac
work=$(mktemp -d "${TMPDIR:-/tmp}/notary-watch-event.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
"$NW_ROOT/scripts/checkpoint-macos.sh" "$state" "$work/checkpoint" "$stage"
"$NW_ROOT/scripts/ci/durable-state.sh" save "$work/checkpoint" "$slot"
