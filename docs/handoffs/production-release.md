# Production release handoff

The production pipeline promotes the exact universal release binary from successful main-push CI. It does not recompile with signing credentials loaded. Native tests and installer startup run on Apple Silicon and Intel; all jobs use macOS. The qualified CI toolchain is Xcode 16.4.

The [distribution guide](../distribution.md) owns setup, commands, credential names and recovery instructions. `scripts/ci/start-release.sh` is the operator entry point. Candidate creation and stable publication are distinct choices; both protected environments require a main-branch human approval.

## Trust and recovery

- Source metadata binds commit, original CI run, version/build, archive hash and actual universal slices before credential use.
- Temporary nonextractable signing identities stay in an owned isolated Keychain; passwords travel through private standard input. Cleanup restores the exact search list, deletes credentials, preserves child failure, and fails promotion if cleanup fails.
- A credential-free initial checkpoint allows import failures to recover. Subsequent allowlisted checkpoints retain immutable submitted bytes, intents and bound UUID receipts. Unknown upload outcomes require reconciliation, never automatic upload retry. Prior distribution attempts require an explicit completed recovery run.
- Apple must accept each named app ZIP and installer DMG. Typed logs must match identifiers and any filename/hash fields. Warning diagnostics are retained; malformed, missing, rejected or contradictory evidence fails. Both app and installer tickets are stapled and validated.
- Final outputs are transactional; fresh acceptance verifies installed copies, signatures, Gatekeeper, tickets, checksums and startup on both architectures.
- Stable publication stages a draft, compares downloaded remote bytes to the accepted candidate, and only then publishes `v<version>`. Existing assets cannot be overwritten. Reused versions identifying another candidate fail closed.

## Verification boundaries

Credential-free CI runs formatting, ShellCheck, Actionlint, Swift tests, synthetic submission/recovery/cleanup/dispatch/publication failures, the installed Security parser, universal optimized compilation, image/copy verification and app startup. Synthetic success does not establish real Developer ID import, Apple acceptance, stapling or public publication.

The required live boundary is provisioning the documented Apple environment secrets/API identifiers, approving signing, and, when explicitly requested, approving publication. The local monitor's saved profile stays independent of CI credentials. No private-key export, trust exception or approval bypass is part of setup.
