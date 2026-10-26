# macOS distribution

Notary Watch targets macOS 14 and later. The distribution build contains Apple Silicon and Intel slices in one app. CI explicitly selects the qualified Xcode 16.4 installation before builds or notarization. All CI jobs use macOS runners; there are no Linux or Windows build targets.

## Production entry point

A successful main-push **CI** run automatically queues **Distribution** for that exact source run. The signing job waits for human approval of **apple-signing**. PR CI, manually dispatched CI, and unsuccessful CI cannot start signing. Automatic candidates retain their verified downloads as workflow artifacts; public publication is still an explicit manual choice.

After the automatic Distribution run completes, publish its verified candidate with a new manual recovery dispatch from a clean main checkout:

```sh
./scripts/ci/start-release.sh --resume PREVIOUS_DISTRIBUTION_RUN_ID --publish
```

Replace `PREVIOUS_DISTRIBUTION_RUN_ID` with the latest completed automatic or manual Distribution run ID for that build. To recover a failed candidate without requesting publication, omit `--publish`. If the original source is older than current main, also pass `--build-run-id ORIGINAL_CI_RUN_ID`.

Only when no Distribution run has ever existed for a successful CI build, use the helper without `--resume` to start its first candidate:

```sh
./scripts/ci/start-release.sh
```

The automatic candidate retains signed downloads as workflow artifacts. A manual recovery with `--publish` publishes `v<app version>` only after Developer ID signing, both Apple notarization stages, stapling, Gatekeeper, fresh Apple Silicon and Intel acceptance, and approval of the **production-release** environment. The **apple-signing** environment separately approves credential use. Both environments are restricted to main and require a human reviewer. A production build uses Swift release optimization and contains both native architectures; CI first packages it with a development signature before the protected job replaces that signature.

The helper selects a successful main-push CI run for the exact clean current main commit and refuses duplicate distribution attempts. `--build-run-id` explicitly selects another retained successful main CI run, including when recovering after main advances. The workflow independently verifies the CI completion event, repository, branch, source SHA, archive checksum, bundle metadata, build number and actual architecture slices before loading credentials. The event source commit must match the selected successful CI run, and immutable artifact IDs remain pinned.

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
4. `ci-required`, which fails if any required job fails or is skipped.

The immutable unsigned artifact is named `Notary-Watch-unsigned-<CI run ID>-a<attempt>`. It contains the packages, checksums, and `build-metadata.json`, which binds the app archive to its commit, run, version, build number, architecture, and SHA-256. CI has read-only repository permissions and does not receive Apple credentials. Artifact retention is 30 days.

The package is built before signing credentials are loaded. Distribution signs these exact binaries without recompiling them.

## Configure Apple signing

In GitHub, open **Settings → Environments**, create **apple-signing**, restrict deployment to **main**, and configure required reviewers. Reviewers authorize use of signing credentials independently of workflow conditions. Protect main and make `ci-required` a required check.

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

Normal main-push CI completion queues a candidate automatically. Use a manual dispatch for recovery or explicit publication. Wait for a successful **main-push** CI run. In **Actions → Distribution → Run workflow**, choose main and enter its CI run ID. Set **resume_run_id** to the latest completed Distribution run for that build. Leave it blank only when no Distribution run has ever existed for the build. Leave **publish_release** unchecked to retain verified signed downloads as workflow artifacts for review.

The equivalent GitHub CLI command, run from the repository root, is:

```sh
gh workflow run distribution.yml --ref main -f build_run_id=123456789 -f resume_run_id=987654321 -F publish_release=false
```

Replace the example CI and recovery run IDs with the actual runs. The workflow refuses PR runs, runs from another repository, unsuccessful CI, and missing or expired artifacts.

The protected signing job:

1. Downloads the original validated universal app and checks its build identity and archive digest.
2. Signs the executable and app from the inside out, with Developer ID, secure timestamps, and Hardened Runtime. It verifies the Apple certificate chain, team, and runtime signature.
3. Submits **Notary-Watch-App-1.2.0-build.42-123456789-universal.zip**. It records the upload intent, exact archive hash, and Apple submission ID before waiting.
4. Requires **Accepted**, retains the diagnostic log even on success, staples and validates the app, and prepares a signed DMG with the Applications shortcut.
5. Submits **Notary-Watch-Installer-1.2.0-build.42-123456789-universal.dmg**, again retaining its hash and ID before waiting.
6. Requires installer acceptance, staples and validates the DMG, verifies Gatekeeper and the copied app, rebuilds the ZIP with the stapled app, and generates final checksums and `release-manifest.json`.
7. Runs fresh acceptance jobs on Apple Silicon and Intel without signing secrets. These verify checksums, signatures, tickets, the installer copy, Gatekeeper, and sample-mode startup.

Version and build numbers in submission names come from the original app's metadata; the CI run ID also distinguishes candidates. The product, version, build, architecture, and app/installer stage stay visible in Apple history. Submission archives do not use generic names such as `installer.zip` or `submit.zip`.

An initial credential-free checkpoint permits recovery from import failures. Checkpoints then retain exact signed archives, bound receipts, and validated allowlisted Apple diagnostic fields after each stage, separately from final downloads. Raw client output, working directories and credential scratch files are never uploaded. A receipt lock prevents concurrent use; each receipt binds the UUID to source commit, version/build, architecture, stage, original CI run, filename and submitted SHA-256. Accepted logs must match the ID, status and any filename/hash fields Apple returns. Error diagnostics, malformed evidence or missing logs block promotion. They do not contain private keys, exported identities, or the temporary signing Keychain. The final signed artifact is named `Notary-Watch-signed-<distribution run ID>-a<attempt>`.

## Resume without duplicate submissions

A finite wait timeout does not cancel Apple's request. To resume, dispatch **Distribution** with the same **build_run_id** and set **resume_run_id** to the previous distribution run that retained its checkpoint:

```sh
gh workflow run distribution.yml --ref main -f build_run_id=123456789 -f resume_run_id=987654321 -F publish_release=false
```

The helper supports the same recovery:

```sh
./scripts/ci/start-release.sh --build-run-id 123456789 --resume 987654321
```

Add `--publish` only if publication is intended. A new dispatch for a previously attempted build without an explicit recovery run is refused. Workflow reruns are refused; use a new manual dispatch with recovery instead. Recovery must use the latest earlier distribution attempt for that candidate, so an older snapshot cannot hide a newer submission. Missing or expired state on that latest attempt requires reconciliation. The workflow validates the previous run's repository, main branch, workflow, and build-specific checkpoint name. It selects the checkpoint for the latest attempted signing/notarization stage using the stage label, rather than the artifact ID. GitHub artifact IDs are not chronological. If that stage's checkpoint is missing or expired, recovery fails instead of restoring an older snapshot that could omit a submission ID. It restores the exact signed archives and checks the original build identity. Recorded submissions are queried again, never uploaded again. A stapling or ticket-service failure can be retried against the same accepted bytes. A newer build does not interrupt an active distribution run for another build.

**Use a new manual dispatch with resume_run_id after a failure.** A plain “Re-run failed jobs” does not automatically restore a checkpoint from an earlier run attempt. Download and retain diagnostics before the 30-day artifact expiration.

If upload intent exists but no valid Apple ID was recovered, the operation fails and refuses another submission. Reconcile the request in Apple history before any new upload. Complete runner loss before a checkpoint upload can also require manual reconciliation; checkpointing cannot guarantee recovery of an ID that never reached durable storage.

DMG creation retries at most three times and only when the complete error is exactly `hdiutil: create failed - Resource busy`. Stapling retries at most three times for ticket-service errors 65 or 68. Other errors fail immediately. Each notary wait is bounded, and the outer signing job has a 90-minute limit. None of these limits promises Apple's turnaround time.

## Stable production publication

Set **publish_release** to true only when publication is intended. After both fresh acceptance jobs pass, approve the **production-release** environment. The workflow creates a draft `v<app version>` release at the exact accepted source commit, uploads only the ZIP, DMG, manifest and checksums, downloads every uploaded asset and compares its digest, then makes the complete release stable and latest. It verifies the published tag resolves to the accepted source commit. A version already used for another commit or candidate fails; bump `CFBundleShortVersionString` for a new public version. A retry may fill missing draft assets but never overwrite them or mutate published release assets.

Final downloads have different hashes from submitted archives because stapling and repacking change bytes. The release manifest records submitted hashes; `SHA256SUMS` covers the final downloads. Final output is staged transactionally and previous complete output survives a packaging failure.

A successful source test or development package does not certify Developer ID signing, Apple acceptance, publication, or a real installed-user launch. The release workflow records those gates separately. See [the production handoff](handoffs/production-release.md) for implementation and operator boundaries.

## References

- [Apple: Creating distribution-signed code for the Mac](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
- [Apple: Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [GitHub: Signing Xcode applications](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [GitHub: Hosted runner platforms](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)

The design follows the macOS packaging patterns in Hikyo, Agent Job Queue, and Takedown: isolated signing credentials, named submission archives, explicit acceptance gates, preserved recovery evidence, and an Applications drag target. Their Linux and Windows pipelines are outside this project's scope.
