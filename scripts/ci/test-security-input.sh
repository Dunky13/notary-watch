#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib/macos.sh
source "$(dirname -- "$0")/../lib/macos.sh"
# shellcheck source=scripts/lib/security-input.sh
source "$(dirname -- "$0")/../lib/security-input.sh"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
fail() { nw_fail "Security input regression: $*"; }
# Exercise the installed parser with a read-only help command and fixture values.
# shellcheck disable=SC2016
fixture='fixture "quoted" \backslash $literal ; literal'
fixture+=$'\x60literal\x60'
if nw_security_private help "$fixture" > "$work/output" 2>&1; then fail 'Unknown command unexpectedly succeeded.'; fi
grep -Fx "security: help: no such command: $fixture" "$work/output" >/dev/null || fail 'Parser changed the fixture argument.'
if (nw_security_private help $'fixture\nhelp') > "$work/output" 2>&1; then fail 'Newline injection was accepted.'; fi
long=$(printf '%04000d' 0)
if (nw_security_private help "$long") > "$work/output" 2>&1; then fail 'Oversized command was accepted.'; fi
printf 'Installed Security parser preserved literal input and rejected command injection/truncation.\n'
