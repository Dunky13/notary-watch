# macOS distribution

Notary Watch targets macOS 14 and later. The distribution build contains Apple Silicon and Intel slices in one app. All CI jobs use macOS runners; there are no Linux or Windows build targets.

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

The verifier checks the disk image, Applications symlink, app signature, bundle identity, executable hash, and a copy into an owned temporary Applications directory. It does not overwrite the real Applications directory. Universal builds check both architecture slices separately, including on versions of `lipo` that reject multi-architecture verification in one invocation.

## CI

`.github/workflows/ci.yml` runs on main pushes, pull requests, and manual dispatch:

1. Swift formatting, ShellCheck, shell syntax, Actionlint, app metadata, and offline release regressions.
2. The Swift test suite on `macos-15` (Apple Silicon) and `macos-15-intel`.
3. A universal release build, development ZIP and DMG, mounted-image and copy verification, and sample-mode app startup.
4. `ci-required`, which fails if any required job fails or is skipped.

The immutable unsigned artifact is named `Notary-Watch-unsigned-<CI run ID>-a<attempt>`. It contains the packages, checksums, and `build-metadata.json`, which binds the app archive to its commit, run, version, architecture, and SHA-256. CI has read-only repository permissions and does not receive Apple credentials. Artifact retention is 30 days.

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

Use a Developer ID Application identity. A public `.cer` file alone does not contain the private key needed for signing. Export the identity from Keychain Access as a password-protected `.p12`. Generate the team API key in App Store Connect with sufficient notarization permissions. The monitor's saved Keychain profile is independent of these CI credentials.

The signing wrapper is restricted to isolated GitHub-hosted runners. It imports a nonextractable private key into an owned temporary Keychain, selects exactly one matching valid identity, and restores the prior search list. It removes temporary files and the Keychain on success, failure, and ordinary cancellation. Raw secret values are removed from the signing child's environment. Builds and third-party actions are not run with the raw signing inputs in their environment. No trust exceptions or Hardened Runtime exception entitlements are added.

## Run distribution

Wait for a successful **main-push** CI run. In **Actions → Distribution → Run workflow**, choose main and enter its CI run ID. Leave **resume_run_id** blank for the first signing attempt. Leave **publish_release** unchecked to retain verified signed downloads as workflow artifacts for review.

The equivalent GitHub CLI command, run from the repository root, is:

```sh
gh workflow run distribution.yml --ref main -f build_run_id=123456789 -F publish_release=false
```

Replace the example run ID with the actual CI run. The workflow refuses PR runs, runs from another repository, unsuccessful CI, and missing or expired artifacts.

The protected signing job:

1. Downloads the original validated universal app and checks its build identity and archive digest.
2. Signs the executable and app from the inside out, with Developer ID, secure timestamps, and Hardened Runtime. It verifies the Apple certificate chain, team, and runtime signature.
3. Submits **Notary-Watch-App-1.2.0-universal.zip**. It records the upload intent, exact archive hash, and Apple submission ID before waiting.
4. Requires **Accepted**, retains the diagnostic log even on success, staples and validates the app, and prepares a signed DMG with the Applications shortcut.
5. Submits **Notary-Watch-Installer-1.2.0-universal.dmg**, again retaining its hash and ID before waiting.
6. Requires installer acceptance, staples and validates the DMG, verifies Gatekeeper and the copied app, rebuilds the ZIP with the stapled app, and generates final checksums and `release-manifest.json`.
7. Runs fresh acceptance jobs on Apple Silicon and Intel without signing secrets. These verify checksums, signatures, tickets, the installer copy, Gatekeeper, and sample-mode startup.

Version numbers in submission names come from the original app's metadata. The product, version, architecture, and app/installer stage stay visible in Apple history. Submission archives do not use generic names such as `installer.zip` or `submit.zip`.

Checkpoint artifacts retain public signed archives, receipts, and diagnostics after each stage, separately from final downloads. They do not contain private keys, exported identities, or the temporary signing Keychain. The final signed artifact is named `Notary-Watch-signed-<distribution run ID>-a<attempt>`.

## Resume without duplicate submissions

A finite wait timeout does not cancel Apple's request. To resume, dispatch **Distribution** with the same **build_run_id** and set **resume_run_id** to the previous distribution run that retained its checkpoint:

```sh
gh workflow run distribution.yml --ref main -f build_run_id=123456789 -f resume_run_id=987654321 -F publish_release=false
```

The workflow validates the previous run's repository, main branch, workflow, and build-specific checkpoint name. It restores the exact signed archives and checks the original build identity. Recorded submissions are queried again, never uploaded again. A stapling or ticket-service failure can be retried against the same accepted bytes. A newer build does not interrupt an active distribution run for another build.

**Use a new manual dispatch with resume_run_id after a failure.** A plain “Re-run failed jobs” does not automatically restore a checkpoint from an earlier run attempt. Download and retain diagnostics before the 30-day artifact expiration.

If upload intent exists but no valid Apple ID was recovered, the operation fails and refuses another submission. Reconcile the request in Apple history before any new upload. Complete runner loss before a checkpoint upload can also require manual reconciliation; checkpointing cannot guarantee recovery of an ID that never reached durable storage.

DMG creation retries at most three times and only when the complete error is exactly `hdiutil: create failed - Resource busy`. Stapling retries at most three times for ticket-service errors 65 or 68. Other errors fail immediately. Each notary wait is bounded, and the outer signing job has a 90-minute limit. None of these limits promises Apple's turnaround time.

## Optional publication

Set **publish_release** to true only when you intend to publish. After both fresh acceptance jobs pass, the workflow creates a GitHub prerelease named `build-<original CI run number>-<commit prefix>` containing the exact signed ZIP, DMG, manifest, and checksums. Existing releases are not overwritten. A successful source test or development package does not certify Developer ID signing, Apple acceptance, publication, or a real installed-user launch.

## References

- [Apple: Creating distribution-signed code for the Mac](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/)
- [Apple: Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [GitHub: Signing Xcode applications](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [GitHub: Hosted runner platforms](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)

The design follows the macOS packaging patterns in Hikyo, Agent Job Queue, and Takedown: isolated signing credentials, named submission archives, explicit acceptance gates, preserved recovery evidence, and an Applications drag target. Their Linux and Windows pipelines are outside this project's scope.
