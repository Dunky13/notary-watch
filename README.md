# Notary Watch

A native macOS dashboard for Apple notarization submissions. Built with SwiftUI and Apple's `notarytool`, with no web server or third-party dependencies.

## Open the app

The ready-to-run bundle is `dist/Notary Watch.app`. Open it in Finder, or from this project directory:

```sh
open "dist/Notary Watch.app"
```

Requires macOS 14 or later. The included build targets the architecture of the Mac that builds it. Xcode must be installed and selected so `xcrun --find notarytool` succeeds.

## Install from a disk image

Open `Notary-Watch-Installer-<version>-universal.dmg`, drag **Notary Watch.app** to the **Applications** shortcut, eject the disk image, and launch the installed app. The universal build supports Apple Silicon and Intel Macs. Local `*-development.dmg` files use an ad hoc signature; the protected distribution workflow produces Developer ID-signed and notarized downloads.

To build and verify the local drag-and-drop installer:

```sh
./scripts/build-app.sh --universal --output "dist/universal/Notary Watch.app"
./scripts/package-macos.sh --app "dist/universal/Notary Watch.app"
./scripts/verify-macos.sh dist/packages/*-development.dmg development
```

See [macOS distribution](docs/distribution.md) for CI, Apple signing configuration, descriptive notarization names, checkpoint recovery, and optional publication.

## Guided setup

On first launch, the app opens a five-step setup guide. You can close it to explore sample data and reopen it with **Connect to Apple** or the key button in the toolbar. Existing connections open the saved-profile shortcut instead.

1. **Check your Mac.** The app checks that Apple's `notarytool` is available. If Xcode is missing or incorrectly selected, it explains how to install and select it and provides a **Check again** button.
2. **Find your Apple account.** Open Apple Developer from the app and confirm the email you use for that membership. The screen also explains where to find your Apple account email in System Settings. Enter the developer email to continue.
3. **Choose your developer team.** The app suggests Team IDs from installed Developer ID signing certificates. These are suggestions, not proof of an Apple account connection. Confirm the intended team, or open your Apple Developer membership page and enter a different 10-character Team ID. No installed certificate is required for monitoring.
4. **Create an app password.** Open Apple Account from the app. Choose **Sign-In and Security → App-Specific Passwords**, generate a password named Notary Watch, and keep it ready. Two-factor authentication must be enabled. Confirm in the app that you have the generated password.
5. **Save and connect.** Review your account, team, and Keychain profile name. Give the profile a friendly display name such as Personal or Work if you want. Click **Open Terminal prompt**. The app fills in the account and team so Apple's tool asks only for the generated password, with characters hidden while you type. After Apple confirms that the credentials were saved, return to the app and click **Check connection**.

The guide finishes only after Apple returns your real submission history. An empty history is a valid connection. Opening Terminal or confirming that a password was generated does not mark setup complete. You can go back to correct your details, cancel a check, and retry a failed connection.

The footer stays visible even if a step needs scrolling. Back preserves your account and team entries. The app does not save an unfinished setup or your email address in its preferences; close and reopen setup to start again.

### Already have a Keychain profile?

Choose **I already have a Keychain profile** on the first screen. Enter the exact profile name used by your existing notarization workflow. Under **Custom Keychain**, select its Keychain file if that workflow uses one. Click **Check connection** to verify it with Apple. You can also choose **Help me create a new profile instead**; that route suggests a unique new profile name so your previous connection is not reused accidentally.

### If Terminal cannot open

Use **Copy command** on the final screen and paste the command into Terminal. The generated command contains your account email, Team ID, and chosen profile name, with each value safely quoted. It contains no password and does not ask the API-key questions. The manual equivalent is:

```sh
xcrun notarytool store-credentials "notary-watch" --apple-id "YOUR_EMAIL" --team-id "YOUR_TEAM_ID"
```

Replace the email and Team ID, then enter the generated app-specific password at Apple's hidden prompt.

### Privacy and connection errors

Passwords and API keys are handled by Apple's tool and Keychain. Notary Watch never asks you to enter a password into its own interface. When you click **Open Terminal prompt**, the app creates a private, executable temporary script containing only the account email, Team ID, and profile name. It opens that script in Terminal without Apple Events automation. The script removes itself after Apple's command exits. No password appears in the script or process arguments.

After a successful connection, the app saves the profile list (display names, stable IDs, Keychain profile names, and optional Keychain paths), active profile selection, and auto-refresh preference in macOS preferences. Histories and downloaded logs remain in memory until closed, except logs you explicitly save and private temporary command output deleted after each request. There is no telemetry or local HTTP server.

If a saved profile fails, check that Xcode is selected, your Keychain is unlocked, and the profile belongs to the intended developer team. The app displays Apple's error, keeps previous successful history on a failed refresh, and preserves the previous connection on a failed profile switch.

## Multiple profiles

Use the profile menu at the bottom of the sidebar to choose which Apple account or developer team to monitor. The active profile also appears in the window title bar. Each profile is a saved reference to a `notarytool` Keychain profile, optionally in a custom Keychain file.

- **Set up a new profile** opens the guided setup with a unique new Keychain profile name. Finish the wizard to save and activate it without replacing your other saved profiles.
- **Use an existing Keychain profile** lets you add credentials that were already saved by another notarization workflow. Enter the exact Keychain profile name, optionally select its Keychain file, and choose a friendly display name such as Personal, Work, or CI.
- Choose a saved profile to verify it with Apple and load its history. A failed or cancelled switch preserves the previous active profile and its results. Successful switches clear the previous log, selection, search, and filters before displaying the target history. The app displays one profile at a time.
- **Manage profiles** opens the profile list. Select a profile to rename its display label, check or activate its connection, or remove it. Changing a display label does not rename its Keychain credentials.
- Removing a profile requires confirmation and removes only its reference from this app. Credentials remain in Keychain and can be added again. Removing the active profile selects the next saved profile and requests its history. If that request fails, the new profile shows an error and an empty list; the removed profile's history is never shown under the new name.

Your existing single-profile connection migrates automatically on first launch of this version. The app remembers all saved profiles and which one was active across restarts. Adding the same credential reference again updates the existing entry instead of creating a duplicate. The same Keychain profile name can be saved separately for different custom Keychain files. Malformed or unsupported saved-profile metadata is preserved and reported rather than silently reset.

## Use the dashboard

- Browse **All submissions**, **In progress**, **Accepted**, and **Needs attention**. Invalid, rejected, and unknown statuses remain visible.
- Search filenames or submission IDs with **Command-F**. Select a row to inspect the full filename, submission ID, date, and status.
- Use **Command-R** or the toolbar refresh button to fetch current history. Auto-refresh runs every 30 seconds while the window is active and can be paused from the toolbar. Calls have a 60-second timeout and do not overlap.
- **Check status** refreshes only the selected request. It does not advance the full-history freshness timestamp.
- **Fetch log** retrieves a completed request's diagnostic log. Accepted submissions can still contain warnings. Click **JSON** to read, copy, or save the original JSON.
- **Explore sample data** opens an explicitly labeled example workspace without Apple credentials. Exit it to return to the connection screen or your saved live profile. Sample mode never silently replaces live results after an error.

To launch directly into sample mode:

```sh
open "dist/Notary Watch.app" --args --demo
```

Quit an already-running instance first when changing launch arguments.

## Production releases

The [distribution guide](docs/distribution.md) is the entry point for protected Developer ID releases, stable GitHub publication, and recovery. From a clean main checkout with green CI, run `./scripts/ci/start-release.sh` to prepare a signed candidate, or add `--publish` to request a stable release after approval.

## Build and test

Requires Xcode with a Swift 6 toolchain. From this project directory:

```sh
swift test -j 2
./scripts/build-app.sh
open "dist/Notary Watch.app"
```

The app build script creates the icon and `.app` bundle and applies a local ad hoc signature. The separate packaging script creates the ZIP and drag-and-drop DMG. Local build and packaging commands do not install the app, submit it to Apple, or create a Developer ID distribution signature. You can move the bundle to Applications yourself. Open `Package.swift` in Xcode to develop the app.

## Scope and limits

Monitoring is read-only and runs `notarytool history`, `info`, and `log`. Guided setup additionally launches `notarytool store-credentials` in Terminal when you click its button. The app does not submit, cancel, sign, staple, or modify any archive. Its only Apple network access is through `notarytool` using your selected credentials. Exporting a log writes only the file you select.

The list shows the history returned by Apple's current service for the selected team. It is not a permanent archive of every historical request, and it does not include the separate legacy `altool` history. An accepted submission is not proof that a particular local artifact has been stapled or verified by Gatekeeper.

## Project layout

- `Sources/NotaryCore`: typed Apple JSON models, command execution, dashboard and setup state, profile storage and migration, safe setup commands, certificate metadata parsing, and sample data.
- `Sources/NotaryWatch`: SwiftUI window, sidebar, history, inspector, connection flow, log export.
- `Tests/NotaryCoreTests`: decoding, process failures/timeouts/cancellation, argument and shell safety, setup step validation, team discovery, profile migration and history isolation, filtering, and asynchronous connection regressions.
- `Resources` and `scripts`: app metadata, generated icon, and local bundle packaging.

## References

- [Apple: Migrating to the latest notarization tool](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)
- [Apple: Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
