# Production release handoff

## Contract and frozen baseline

Notary Watch builds with native Swift Package Manager release optimization, combines arm64 and x86_64 into one universal macOS 14+ app, then produces an app ZIP and drag-and-drop DMG. Bundle identity remains `dev.notarywatch.local`. No updater feed or separate update-signing authority exists. The isolated Developer ID team and existing user preferences/Keychain profiles remain authoritative.

The implementation baseline was main `cbf9dcf1b9c446fa312eef32445fc6af4d77f625`. Read-only live capture on 2026-10-26 found required fresh `ci-required` checks, enforced administrator protection, no approving PR review requirement, and two release environments (`apple-signing`, `production-release`) each requiring a reviewer and permitting only the main branch. Main CI run 40335339970 succeeded; automatic Distribution 40337094622 was waiting for signing approval. The earlier failed signing run 40322615271 stopped before import or Apple upload. These are historical witnesses, not qualification of this implementation.

The user explicitly authorized PR, merge, removal of only those two recurring release reviewer rules, real Apple submissions, same-candidate qualification and stable publication. Main protection, branch/tag deployment restrictions, isolated secrets and machine acceptance gates remain. No other environment is in scope.

## Automatic policy and flow

Successful same-repository main-push CI starts the full stable release. Version is configured major/minor plus original CI workflow run number as patch; the same number is the bundle build. The exact CI attempt, artifact ID, source, archive hash, app metadata and actual universal slices are checked before credentials. CI remains credential-free. Xcode 16.4 remains the build/acceptance toolchain; only notarytool uses qualified Xcode 26.3.

The signer replaces signatures without rebuilding, using an isolated nonextractable temporary identity, hardened runtime and timestamps. Private-stdin Security commands, exact search-list restoration, credential deletion and cleanup failure propagation remain gates. App ZIP submission/Accepted diagnostic/staple precedes DMG construction; DMG signing/submission/Accepted diagnostic/staple precedes final output. Quarantined copy Gatekeeper checks and fresh ARM/Intel signature/ticket/install/startup acceptance remain mandatory.

The [distribution guide](../distribution.md) owns operator commands and configuration. Normal operation needs no dispatch or reviewer approval. Manual recovery enters the same stable path and must reference the latest completed distribution attempt for the original successful main-push CI.

## Durable recovery

Private draft `notary-state-ci-<original CI run>` retains immutable checksum-paired source, per-execution stage snapshots, inline upload intents/UUID receipts, and exact finalized downloads. It must never become public. Only allowlisted regular files enter custody; archives, source/run/attempt bindings and exact asset IDs are checked during restore. Ordinary artifacts are convenience copies, not the long-term recovery authority.

An intent is durably verified before any upload, and a captured UUID is persisted immediately. Runner loss between the Apple upload and durable UUID persistence leaves a reservation requiring reconciliation; it never causes a blind second upload. Missing newest state cannot fall back to an earlier attempt. A bound pending/diagnosed transport state can resume the same UUID automatically. Terminal/mismatched/malformed evidence stops and alerts. Unknown upload identity needs Apple-history reconciliation. Cancellation is not automatically reversed.

Release continuation runs after Distribution completion and every fifteen minutes, with at most twelve attempts per original build. Final custody permits retrying acceptance/publication without importing credentials, recompilation, resigning or repacking. Publication stages a draft, verifies the exact four remotely downloaded assets, then publishes stable; existing assets cannot be overwritten. Older delayed candidates cannot move latest backwards.

## Validation and remaining evidence

The required local checks are `scripts/ci/check.sh`, including offline signing/cleanup, submission/log binding, durable custody corruption/path/identity tests, controller recovery tests and transactional publication failures. `ci-required` additionally requires native Swift tests on ARM/Intel and universal installer packaging/startup on the hosted selected toolchain.

PR CI run 40352020268 passed both native test jobs and universal packaging but exposed an inherited-run-ID assumption in the inline custody fixture and an undeclared ripgrep dependency. Fixtures now set their execution identity explicitly, and the portable leak scan fails closed on scanner errors. The full shell check batch was reproduced with hosted run variables before the repair was pushed.

Synthetic providers establish failure contracts only. Real Developer ID import, both Accepted UUIDs and logs, both staples, native acceptance, same-candidate continuation, published asset IDs/hashes and independent public downloads must be reported separately from source tests. Qualification evidence belongs in the release execution report; local HTML evidence reports stay outside Git. No provider success is inferred from these implementation notes.

## First real hosted boundary

Merged source `260884645ca2c94c259728638d673e9729a76493` passed main CI 40354420872 (build 9, version 1.2.9). Distribution 40354745932 automatically verified its exact artifact, established durable source custody and completed real isolated Developer ID signing. Xcode 16.4 notarytool then trapped with `Trace/BPT trap: 5` during app submit without returning a UUID. Its durable pre-upload intent and signed ZIP hash `eb69b9bcf527106cab4352fbf2e428e7f8ee16b8802e30814a8fe47ed0381684` survived. No Apple acceptance or publication is inferred.

Two local history checks under the existing Notary Watch profile found no matching descriptive filename. The ambiguous candidate remains preserved and is retired, rather than uploaded again. An immutable, exact-execution retirement record stops future recovery without deleting the reservation. The temporary one-second qualification timeout was removed, restoring the original default-ten-minute policy.

The repair pins only the notarization client to Xcode 26.3, whose installed availability and version are checked in credential-free CI and signing preflight. Build/acceptance remain on Xcode 16.4. The investigation's controlled older/newer client comparison and successful Hikyo uploads supply corroborating evidence; this repository still requires its own real newer-client, recovery and publication qualification.

## Hosted runner loss before any signing

Main source `a486d349081a2580ec72b084357c95ab631987bf` passed CI 40359374193 (build 11, version 1.2.11). Distribution 40360374463 never acquired a runner for source-verification job 121703872053. GitHub annotated the job with `The job was not acquired by Runner of type hosted even after multiple attempts` and a macOS ARM capacity notice. Its source job ended cancelled with runner ID zero and no steps; signing and dependent jobs were skipped. The overall workflow failed. This is not an app-signing or Apple result.

Continuation 40366380399 then returned `No eligible continuation` because no durable checkpoint existed. Complete-lineage proof now covers pre-signing failures. Both resolver and controller require affirmative evidence that every credential-bearing operation was skipped in every retained attempt before initializing state from the same exact successful CI artifact. API-only/preflight/custody steps may have run. Only absent, empty or source-only custody permits reinitialization; every existing state snapshot must be restored. Cancelled workflows are not automatically revived. The original twelve-attempt limit remains.

API-only source verification, continuation and the aggregate check use Ubuntu. All build, signing, Apple/toolchain and ARM/Intel installation acceptance gates retain their native macOS runners and policies. A required Ubuntu CI job exercises controller/no-execution recovery and native-tar custody restoration. The original main source failed the new no-execution recovery regression; repaired source passes locally. Hosted validation and the original candidate's real Apple flow still need qualification.

## Draft identity and real wait recovery

Same-candidate recovery run 40389917741 reached preflight and initial state for CI 40359374193, then created private draft 424692075 but failed immediate list rediscovery before any signing operation. Draft creation now captures and validates GitHub's exact returned ID. Asset uploads/downloads and publication use exact IDs and verify remote bytes; ambiguous create failures never trigger a blind second POST. The initial workflow checkpoint precedes durable writes.

GitHub's read-only repository token cannot see private drafts. Trusted-main source and controller jobs now use `contents: write` in the existing main-only production-release environment, the minimum permission GitHub requires for draft visibility. They receive no Apple secrets. Build/PR permissions and both environment branch restrictions remain unchanged. A validated job-local release-ID pointer is checked against the private draft, tag and original source on every use.

Main source `059f9c9c787b8aa801ca3e9469d62bb2bdb8347f` passed CI 40389890564 (version 1.2.13). Automatic Distribution 40390348489 signed and submitted app ZIP `Notary-Watch-App-1.2.13-build.13-40389890564-universal.zip`, SHA-256 `93cecd501b5e29ccdade21a445893523ddf7c00acb5efbd6c7ae288da20d1cf2`. Its real UUID is `e308ed51-24d8-4d71-96f3-32cac8f67b29`. A controlled one-second wait returned exit 124 without JSON and was incorrectly classified as terminal. Independent real Apple info and diagnostic reads later established Accepted with the matching UUID, filename and hash. No installer acceptance or publication follows from that app-only result.

An empty failed wait now invokes a bounded read-only info observation of the retained UUID, preserving wait exit 124. Pending remains retryable; Accepted requires a fresh matching diagnostic log with filename/hash. Nonempty malformed/mismatched waits and authentication errors remain terminal. Optional trusted-main `checkpoint_probe=installer` stops only after a new real UUID has reached durable custody; the default automatic continuation resumes it without uploading again. This permits deterministic recovery qualification without claiming a synthetic Apple state. The original app UUID must be reused. Both installer acceptance, staples, fresh ARM/Intel acceptance and public downloads still require real hosted evidence.
