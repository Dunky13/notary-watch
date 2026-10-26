#!/bin/bash
set -euo pipefail
cd "$(dirname -- "$0")/../.."
xcrun swift-format lint --strict --recursive Sources Tests scripts/make-icon.swift Package.swift
shellcheck scripts/*.sh scripts/lib/*.sh scripts/ci/*.sh
for script in scripts/*.sh scripts/lib/*.sh scripts/ci/*.sh; do bash -n "$script"; done
actionlint
plutil -lint Resources/Info.plist
bash scripts/ci/test-release.sh
