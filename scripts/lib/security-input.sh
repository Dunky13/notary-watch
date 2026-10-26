#!/bin/bash
# security's interactive parser reads one command from stdin. Passwords never
# become process arguments; one command per invocation preserves its exit code.
nw_security_private() {
  local argument quoted command_line='' LC_ALL=C
  for argument in "$@"; do
    [[ $argument != *$'\n'* && $argument != *$'\r'* ]] || nw_fail 'Signing input contains an unsupported line break.'
    quoted=${argument//\\/\\\\}
    quoted=${quoted//\"/\\\"}
    command_line+="\"$quoted\" "
  done
  # Apple's interactive parser has a 4096-byte line buffer. Never truncate input.
  [[ ${#command_line} -lt 4000 ]] || nw_fail 'Signing command exceeds the secure input limit.'
  printf '%s\n' "$command_line" | security -iq
}
