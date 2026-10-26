#!/bin/bash
set -euo pipefail
cd "$(dirname -- "$0")/../.."
xcrun swift-format lint --strict --recursive Sources Tests scripts/make-icon.swift Package.swift
shellcheck scripts/*.sh scripts/lib/*.sh scripts/ci/*.sh
for script in scripts/*.sh scripts/lib/*.sh scripts/ci/*.sh; do bash -n "$script"; done
actionlint
plutil -lint Resources/Info.plist
bash scripts/ci/test-release.sh
bash scripts/ci/test-notary-evidence.sh
bash scripts/ci/test-publish.sh
bash scripts/ci/test-security-input.sh
bash scripts/ci/test-dispatch.sh
bash scripts/ci/test-release-output.sh
bash scripts/ci/test-durable-state.sh
bash scripts/ci/test-continuation.sh
bash scripts/ci/test-retirement.sh
bash scripts/ci/test-unstarted.sh
bash scripts/ci/test-durable-restore.sh
