# macOS distribution

Notary Watch targets macOS 14 and later. The distribution build contains Apple Silicon and Intel slices in one app. Builds remain on qualified Xcode 16.4. The notarization client is separately pinned to Xcode 26.3 because the first real hosted 16.4 upload trapped before returning a UUID. Credential-free CI verifies both selections; signing preflight repeats that check before credentials. No fallback or rebuild accompanies client selection. Builds, signing and native acceptance use macOS. API-only source verification, continuation and the CI aggregate use hosted Ubuntu; there are no Linux or Windows product builds.

## Production entry point

A successful same-repository main-push **CI** run automatically starts **Distribution**, which publishes a stable release only after both native acceptance jobs pass. PR CI, manual CI, foreign repositories and unsuccessful CI cannot supply release artifacts. The required branch-protection context is `ci-required`, with strict freshness and administrator enforcement.

The standing release authority permits trusted protected-main automation to use the existing isolated Apple secrets and publish complete verified candidates. Only the recurring reviewer rules on **apple-signing** and **production-release** are removed. Both environments retain their exact selected-main branch restriction. There is no routine signing, deployment, version-entry or publication approval.

GitHub exposes private release drafts only to identities with push access. Source resolution and continuation therefore use `contents: write` in the existing main-only **production-release** environment to read durable custody. These API-only jobs receive no Apple secrets. Build and PR jobs retain read-only repository permissions.

CI derives the stable version before compilation: the configured major/minor in `Resources/Info.plist` plus the original CI workflow run number as its patch (for example `1.2.7` for CI build 7). The bundle build number remains that original run number. Each successful main push is eligible, including release automation changes. No nightly channel or updater is introduced. The existing `dev.notarywatch.local` bundle identity, Developer ID team, user Keychain profiles and preferences remain authoritative. There is no Sparkle feed, Homebrew integration or separate update-signing key in this repository.

Recovery uses the same original CI run and version. For exceptional operator recovery, from a clean current main checkout:

```sh
./scripts/ci/start-release.sh --build-run-id ORIGINAL_CI_RUN_ID --resume LATEST_DISTRIBUTION_RUN_ID
```

This enters the same automatic stable publication path. `--publish` remains an optional compatibility spelling and has no separate effect. The workflow refuses duplicate fresh candidates and reruns. Manual dispatch requires the exact successful main-push source and latest completed recovery run; it cannot authorize PR artifacts.

## Local drag-and-drop installer

From the repository root:

```sh
./scripts/build-app.sh --universal --output "dist/universal/Notary Watch.app"
./scripts/package-macos.sh --app "dist/universal/Notary Watch.app"
./scripts/verify-macos.sh dist/packages/*-development.dmg development
```

For version 1.2.0 this produces:

- `dist/packages/Notary-Watch-App-1.2.0-universal-development.zip`
- `dist/packages/Notary-Watch-Installer-1.2.0-universal-development.dmg`
- `dist/packages/SHA256SUMS`

Open the DMG, drag **Notary Watch.app** to **Applications**, eject the image, and launch the installed app. The image also includes short installation instructions. Installing does not alter saved profiles or Keychain credentials. The existing bundle identifier is preserved so upgrades keep the app's preferences.

Local development packages use an ad hoc signature. Developer ID distribution and Apple acceptance are separate operations described below. Normal packaging never reads Apple signing credentials or submits to Apple.

The verifier checks the disk image, Applications symlink, app signature, bundle identity, executable hash, and a copy into an owned temporary Applications directory. It does not overwrite the real Applications directory. Universal builds inspect the architecture inventory with `lipo -archs` and require both Apple Silicon and Intel slices, avoiding incompatible `-verify_arch` argument parsers across Xcode versions. Release acceptance adds quarantine to the owned app copy before Gatekeeper assessment.

## CI

`.github/workflows/ci.yml` runs on main pushes, pull requests, and manual dispatch:

1. Swift formatting, ShellCheck, shell syntax, Actionlint, app metadata, and offline release regressions.
2. The Swift test suite on `macos-15` (Apple Silicon) and `macos-15-intel`.
3. A universal release build, development ZIP and DMG, mounted-image and copy verification, and sample-mode app startup.
4. Credential-free orchestration and native-tar receipt restoration checks on Ubuntu.
5. `ci-required`, which fails if any native or orchestration validation job fails or is skipped.

The immutable unsigned artifact is named `Notary-Watch-unsigned-<CI run ID>-a<attempt>`. It contains the packages, checksums, and `build-metadata.json`, which binds the app archive to its commit, run, version, build number, architecture, and SHA-256. CI has read-only repository permissions and does not receive Apple credentials. Artifact retention is 30 days.

The package is built before signing credentials are loaded. Distribution signs these exact binaries without recompiling them.

## Configure Apple signing

In GitHub, open **Settings → Environments**, create **apple-signing**, restrict deployment to the **main branch only**, with no tag rule. Under the standing automatic-release authority, do not configure recurring reviewers on apple-signing or production-release. Protect main and require fresh `ci-required` checks with administrator enforcement. Keep credentials scoped to apple-signing.

Add these environment secrets. Their values must never be committed:

| Secret | Value |
| --- | --- |
| `APPLE_DEVELOPER_ID_P12_BASE64` | Base64 of a password-protected `.p12` containing the Developer ID Application certificate and its private key. |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | The `.p12` export password. |
| `APPLE_NOTARY_KEY_P8` | The complete App Store Connect team API private key, including PEM header, footer, and newlines. |

Add these environment variables:

| Variable | Value |
| --- | --- |
| `APPLE_SIGNING_IDENTITY` | Full identity name: `Developer ID Application: Your Name (TEAMID1234)`. |
| `APPLE_TEAM_ID` | Your 10-character Apple Developer Team ID. |
| `APPLE_NOTARY_KEY_ID` | The App Store Connect team API key ID. |
| `APPLE_NOTARY_ISSUER_ID` | That team's API issuer UUID. |
| `APPLE_NOTARY_TIMEOUT` | Optional wait per stage, default `10m`, maximum `30m`. |

Use a Developer ID Application identity. A public `.cer` file alone does not contain the private key needed for signing. Use an existing password-protected `.p12` identity export, or explicitly authorize creation of an export through Keychain Access. The pipeline never exports a local private key itself. Generate the team API key in App Store Connect with sufficient notarization permissions. The monitor's saved Keychain profile is independent of these CI credentials.

The secure runtime credential card can install the missing signing inputs. For a repeatable CLI setup, provide an owned private JSON file with permissions `600`, outside the checkout, containing exactly the three secret names and the two API identifier variable names listed above. Secret values must be strings; the P8 string preserves PEM line breaks. Then run:

```sh
./scripts/ci/configure-apple-signing.sh "$SIGNING_CONFIG"
```

Here `SIGNING_CONFIG` is the path to that private file. The helper checks environment protection first, streams values to GitHub over standard input, and never prints them or places them in process arguments. Delete the input file after provisioning. The existing public team and signing identity variables remain separate. A local `notarytool` Keychain profile is not a transferable GitHub credential.

The signing wrapper is restricted to isolated GitHub-hosted runners. It imports a nonextractable private key into an owned temporary Keychain, selects exactly one matching valid identity, and restores the prior search list. It removes temporary files and the Keychain on success, failure, and ordinary cancellation. Passwords enter Apple's interactive Security parser through private standard input with literal quoting, injection guards and an enforced byte limit. They are never command-line arguments. Raw secret values are removed from the signing child's environment. Builds and third-party actions are not run with the raw signing inputs in their environment. No trust exceptions or Hardened Runtime exception entitlements are added.

## Run distribution

Normal main-push CI completion queues the entire stable release automatically. A manual dispatch is an exceptional recovery entry point, not a routine release step:

```sh
gh workflow run distribution.yml --ref main -f build_run_id=123456789 -f resume_run_id=987654321
```

Replace both example IDs with actual evidence. The workflow checks original source, CI attempt and exact artifacts before credentials. It never rebuilds during signing or recovery.

The protected signing job:

1. Downloads the original validated universal app and checks its build identity and archive digest.
2. Signs the executable and app from the inside out, with Developer ID, secure timestamps, and Hardened Runtime. It verifies the Apple certificate chain, team, and runtime signature.
3. Submits **Notary-Watch-App-1.2.0-build.42-123456789-universal.zip**. It records the upload intent, exact archive hash, and Apple submission ID before waiting.
4. Requires **Accepted**, retains the diagnostic log even on success, staples and validates the app, and prepares a signed DMG with the Applications shortcut.
5. Submits **Notary-Watch-Installer-1.2.0-build.42-123456789-universal.dmg**, again retaining its hash and ID before waiting.
6. Requires installer acceptance, staples and validates the DMG, verifies Gatekeeper and the copied app, rebuilds the ZIP with the stapled app, and generates final checksums and `release-manifest.json`.
7. Runs fresh acceptance jobs on Apple Silicon and Intel without signing secrets. These verify checksums, signatures, tickets, the installer copy, Gatekeeper, and sample-mode startup.

Version and build numbers in submission names come from the original app's metadata; the CI run ID also distinguishes candidates. The product, version, build, architecture, and app/installer stage stay visible in Apple history. Submission archives do not use generic names such as `installer.zip` or `submit.zip`.

An initial credential-free checkpoint permits recovery from import failures. Safe checkpoints contain exact signed archives, source/run/version-bound receipts and allowlisted diagnostics. Raw client output, working directories, credentials and Keychains are excluded. Accepted diagnostics must match the UUID/status and any filename/hash returned by Apple. A successful mock does not establish Apple acceptance.

## Durable custody and automatic continuation

The private draft `notary-state-ci-<original CI run>` retains the original credential-free build (`source.tar`), each stage snapshot, pre-upload intent, immediate UUID receipt, and the exact final downloads (`final.tar`). Every archive has its own checksum companion, downloads use exact asset IDs, and existing bytes are compared instead of overwritten. The draft is bound to the original source and is never published. Ordinary workflow artifacts remain a convenient 30-day copy; durable custody has no automatic artifact expiration. Do not delete recovery drafts for active or published candidates without a separate retention decision.

The controller runs after Distribution completion and every fifteen minutes. It considers only the latest completed failed/timed-out attempt of each candidate, validates its successful same-repository main-push CI, and permits at most twelve distribution attempts. Only a bound UUID with a current-execution pending/diagnosed-transport classification can automatically resume Apple observation. Finalized downloads can resume fresh acceptance/publication without signing or repacking. Terminal rejection, contradictory/malformed evidence, missing UUIDs, ambiguous custody and exhausted attempts require operator investigation. Cancellation is not automatically undone.

If execution stops before signing, the controller may start the same pinned candidate only when every retained attempt affirmatively proves that every credential-bearing signing operation was skipped. API-only source resolution, preflight and initial custody writes may have executed. The resolver independently repeats the complete-lineage proof. Only absent, empty or source-only custody permits initial state creation. Any state snapshot, including slot `00`, is restored because an initial recovery snapshot can already contain an older UUID. Missing/malformed evidence, reruns, manual cancellation or a prior signing operation prevents reinitialization. It never clears an upload intent or rebuilds the original CI artifact. API-only orchestration uses Ubuntu so it does not consume the scarce Mac runners required for signing and native acceptance.

Draft creation captures the exact release ID returned by GitHub and validates it with a direct read instead of depending on immediate list visibility. Uploads and read-back verification use exact release and asset IDs. A validated job-local custody pointer is checked again against the private draft, tag and original source before reuse. The ordinary initial checkpoint is uploaded before durable writes so a provider failure cannot discard the credential-free recovery witness.

Checkpoints are selected by attempted stage and execution lineage, never opaque artifact-ID magnitude. Stage completion snapshots take precedence; if a runner dies during a submit/wait stage, only the matching inline intent/UUID snapshot from that same distribution attempt may substitute. An intent is durably verified before upload begins. UUID custody is verified immediately after capture. If upload completes but the UUID never reaches durable storage, recovery retains the intent and refuses another upload; reconcile Apple history before proceeding. There is no claim of atomicity between Apple and GitHub.

A finite wait does not cancel Apple's request. Continuation queries the retained UUID and original signed bytes. It cannot create a fresh upload just because a client timed out. New dispatches independently recheck latest-run ordering under the original-build concurrency lock. Missing latest-stage custody fails closed, rather than restoring an older attempt. The original CI attempt is also checked after ordinary artifacts expire.

When a failed wait returns no JSON, a separately bounded `info` query observes the existing UUID. It preserves the original wait exit code. Pending can continue automatically; Accepted still requires the matching fresh diagnostic log, filename and submitted hash. Authentication failures, malformed or contradictory responses remain terminal. A trusted-main manual qualification may set `checkpoint_probe=installer` to stop immediately after a new real installer UUID reaches durable custody. Automatic continuation uses the default `none` and resumes that UUID. This stop proves receipt recovery only; Apple acceptance and native acceptance remain separate gates.

An exceptional failed candidate may be retired with `scripts/ci/retire-candidate.sh` using a bound record containing schema, commit, original CI run, failed distribution execution, machine-readable reason and UTC retirement time. This verifies the completed failed main Distribution and writes an immutable `retired.json` in its existing private custody draft. Retirement preserves every byte and receipt; it authorizes no retry, acceptance or publication. The controller validates retirement against the latest failed execution before stopping alerts, and the resolver refuses further candidate use. Do not delete an upload intent to clear a failure.

DMG creation retries at most three times and only when the complete error is exactly `hdiutil: create failed - Resource busy`. Stapling retries at most three times for ticket-service errors 65 or 68. Other errors fail immediately. Each notary wait is bounded, and the outer signing job has a 90-minute limit. None of these limits promises Apple's turnaround time.

Installer and copied-app ticket validation retry at most three times, with two-second delays, only for exit 68 accompanied by the observed Apple ticket-service `NSURLErrorDomain Code=-1005` connection loss. Every attempt's diagnostic remains in job output. Authentication failures, invalid tickets, unrelated endpoints/errors and exhausted transport attempts still fail acceptance; recovery keeps the same finalized bytes.

## Stable production publication

After both fresh native acceptance jobs pass, the main-only production-release job creates a draft `v<version>` at the exact accepted source, uploads only the ZIP, DMG, manifest and checksums, downloads every asset and compares its digest, then publishes the complete stable release. A delayed older candidate cannot move the latest pointer backwards. Existing assets are never overwritten; a retry may only fill missing draft assets. The published tag must resolve to the accepted source commit. Durable final custody lets recovery reuse the same accepted download bytes.

Final downloads have different hashes from submitted archives because stapling and repacking change bytes. The release manifest records submitted hashes; `SHA256SUMS` covers the final downloads. Final output is staged transactionally and previous complete output survives a packaging failure.

A successful source test or development package does not certify Developer ID signing, Apple acceptance, publication, or a real installed-user launch. The release workflow records those gates separately. See [the production handoff](handoffs/production-release.md) for implementation and operator boundaries.

## References

- [Apple: Creating distribution-signed code for the Mac](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
- [Apple: Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [GitHub: Signing Xcode applications](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [GitHub: Hosted runner platforms](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)

The design follows the macOS packaging patterns in Hikyo, Agent Job Queue, and Takedown: isolated signing credentials, named submission archives, explicit acceptance gates, preserved recovery evidence, and an Applications drag target. Their Linux and Windows pipelines are outside this project's scope.
