# Production release handoff

The production pipeline promotes the exact universal release binary from successful main-push CI. It does not recompile with signing credentials loaded. Native tests and installer startup run on Apple Silicon and Intel; all jobs use macOS. The qualified CI toolchain is Xcode 16.4.

The [distribution guide](../distribution.md) owns setup, commands, credential names and recovery instructions. `scripts/ci/start-release.sh` is the operator entry point. Successful main-push CI automatically queues a candidate; stable publication remains a distinct manual choice; both protected environments require a main-branch human approval.

## Trust and recovery

- Source metadata binds commit, original CI run, version/build, archive hash and actual universal slices before credential use.
- Temporary nonextractable signing identities stay in an owned isolated Keychain; passwords travel through private standard input. Cleanup restores the exact search list, deletes credentials, preserves child failure, and fails promotion if cleanup fails.
- A credential-free initial checkpoint allows import failures to recover. Subsequent allowlisted checkpoints retain immutable submitted bytes, intents and bound UUID receipts. Unknown upload outcomes require reconciliation, never automatic upload retry. Prior distribution attempts require an explicit completed recovery run, whether the previous attempt was automatically queued or manually dispatched.
- Apple must accept each named app ZIP and installer DMG. Typed logs must match identifiers and any filename/hash fields. Warning diagnostics are retained; malformed, missing, rejected or contradictory evidence fails. Both app and installer tickets are stapled and validated.
- Final outputs are transactional; fresh acceptance verifies installed copies, signatures, Gatekeeper, tickets, checksums and startup on both architectures.
- Stable publication stages a draft, compares downloaded remote bytes to the accepted candidate, and only then publishes `v<version>`. Existing assets cannot be overwritten. Reused versions identifying another candidate fail closed.

## Verification boundaries

Credential-free CI runs formatting, ShellCheck, Actionlint, Swift tests, synthetic submission/recovery/cleanup/dispatch/publication failures, the installed Security parser, universal optimized compilation, image/copy verification and app startup. Synthetic success does not establish real Developer ID import, Apple acceptance, stapling or public publication.

The required live boundary is provisioning the documented Apple environment secrets/API identifiers, approving signing, and, when explicitly requested, approving publication. The local monitor's saved profile stays independent of CI credentials. No private-key export, trust exception or approval bypass is part of setup.

## Automatic candidate queue

`workflow_run` listens to completed **CI** runs on main. The source job and resolver require a successful completed push from this repository, bind the event source SHA to the fetched successful CI run, and retain the existing exact artifact and checksum checks. PR CI, manual CI, failed CI, foreign repositories, mismatched commits and malformed completion events fail before credentials. The selected original run ID is used consistently for concurrency, download handoffs, checkpoints and receipts. Automatic runs retain the protected signing gate and cannot publish; stable publication is explicitly manual.

## Recovery qualification from the first hosted attempt

The first distribution failed in signing setup before credential import, signing or Apple upload because the job began before secret provisioning. Its initial and preparation checkpoints survived. GitHub returned an older checkpoint with a numerically greater artifact ID than the newer preparation checkpoint, so recovery must select by recorded attempt/stage rather than numeric artifact ID. The resolver also checks the previous signing job's highest attempted stage and refuses missing or expired matching state, preventing fallback that could lose an Apple submission UUID.

The existing encrypted Hikyo signing backups and targeted Keychain password entries were verified privately, and this repository's protected Apple environment was provisioned. Actual notarization-key authentication succeeded. No private key was re-exported from Keychain, access controls were unchanged, and temporary decrypted material was removed.
