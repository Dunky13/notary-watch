import NotaryCore
import SwiftUI

enum ConnectionPurpose { case current, addNew, addExisting }

struct ConnectionView: View {
    @ObservedObject var model: DashboardModel
    @StateObject private var flow: SetupFlow
    @Environment(\.dismiss) private var dismiss
    @State private var existingProfile: Bool
    @State private var showCustomKeychain = false
    @State private var operation: Task<Void, Never>?
    @State private var openingTerminal = false
    @State private var commandCopied = false
    @FocusState private var focusedField: Field?
    private enum Field { case email, team, profile }

    init(model: DashboardModel, purpose: ConnectionPurpose = .current) {
        self.model = model
        let initial = purpose == .current ? model.profile : nil
        let setup = SetupFlow(profile: initial)
        if purpose == .current { setup.displayName = model.activeProfile?.displayName ?? "" }
        if purpose == .addExisting { setup.profileName = "" }
        _flow = StateObject(wrappedValue: setup)
        _existingProfile = State(initialValue: purpose == .addExisting || initial != nil)
        _showCustomKeychain = State(initialValue: !(initial?.keychainPath.isEmpty ?? true))
    }
    private var busy: Bool { flow.isBusy || model.isBusy || openingTerminal }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if flow.step == .complete {
                        completion
                    } else if existingProfile {
                        existingProfileForm
                    } else {
                        currentStep
                    }
                    if let error = flow.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(30).frame(maxWidth: .infinity, alignment: .leading).disabled(busy)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 620).tint(Palette.accent)
        .interactiveDismissDisabled(busy)
        .onAppear {
            if !existingProfile { operation = Task { await flow.checkMac() } }
        }
        .onChange(of: flow.step) { _, step in
            commandCopied = false
            switch step {
            case .account: focusedField = .email
            case .team: focusedField = .team
            default: focusedField = nil
            }
        }
        .onDisappear { operation?.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Label("NOTARY WATCH SETUP", systemImage: "checkmark.seal")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(Palette.accent)
                Spacer()
                if flow.step != .complete {
                    Text(existingProfile ? "EXISTING PROFILE" : "STEP \(flow.step.rawValue + 1) OF 5")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if !existingProfile && flow.step != .complete {
                HStack(spacing: 5) {
                    ForEach(0..<5) { index in
                        Capsule().fill(index <= flow.step.rawValue ? Palette.accent : Color.secondary.opacity(0.15))
                            .frame(height: 3)
                    }
                }.accessibilityLabel("Step \(flow.step.rawValue + 1) of 5")
            }
            Text(
                flow.step == .complete ? "You’re connected." : existingProfile ? "Use a saved profile" : flow.step.title
            )
            .font(.system(size: 26, weight: .semibold)).tracking(-0.6)
        }.padding(30)
    }

    @ViewBuilder private var currentStep: some View {
        switch flow.step {
        case .tools: toolsStep
        case .account: accountStep
        case .team: teamStep
        case .password: passwordStep
        case .connect: connectStep
        case .complete: completion
        }
    }

    private var toolsStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            intro(
                "Let’s connect your Apple notarization account, one step at a time. You’ll need access to your Apple Developer membership and your Apple account."
            )
            HStack(alignment: .top, spacing: 12) {
                if flow.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: flow.toolsVersion != nil ? "checkmark.circle.fill" : "wrench.and.screwdriver")
                        .foregroundStyle(Palette.accent)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        flow.isBusy
                            ? "Checking Apple’s tools…"
                            : flow.toolsVersion != nil ? "Apple’s notarization tool is ready" : "Xcode needs attention"
                    )
                    .font(.system(size: 13, weight: .semibold))
                    if let version = flow.toolsVersion {
                        Text(version).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    } else if !flow.isBusy {
                        Text("Install Xcode, open it once, and select its command-line tools in Xcode’s settings.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        externalLink("Get Xcode", "https://developer.apple.com/xcode/")
                    }
                }
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            if !flow.isBusy { Button("Check again") { operation = Task { await flow.checkMac() } }.controlSize(.small) }
            Divider()
            Button("I already have a Keychain profile") {
                existingProfile = true
                flow.error = nil
            }
            .buttonStyle(.link).disabled(busy)
            note("You can close setup at any time and explore the dashboard with sample data.")
        }
    }

    private var accountStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            intro(
                "Use the email address you use to sign in to Apple Developer. Apple calls this your Apple Account, or Apple ID."
            )
            instruction(
                "1", "Find the email on your Mac",
                "Open System Settings, click your name, then Sign-In & Security. Your developer account may use a different email from iCloud."
            )
            instruction(
                "2", "Confirm it on Apple Developer",
                "Open your developer account and sign in. Use the email for the account that submits your apps.")
            externalLink("Open Apple Developer account", "https://developer.apple.com/account/")
            VStack(alignment: .leading, spacing: 8) {
                Text("Apple Developer account email").font(.system(size: 12, weight: .medium))
                TextField("you@example.com", text: $flow.email).textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .email).onSubmit { flow.advance() }
                    .accessibilityLabel("Apple Developer account email")
                note("No Apple account password is needed here.")
            }
        }
    }

    private var teamStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            intro(
                "Your Team ID is a 10-character code for your Apple Developer membership. Choose the team that made your notarization submissions."
            )
            if !flow.teams.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("FOUND ON THIS MAC").font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(
                        .secondary)
                    ForEach(flow.teams) { team in
                        Button {
                            flow.teamID = team.id
                        } label: {
                            HStack {
                                Image(systemName: flow.details.teamID == team.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(Palette.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(team.name).font(.system(size: 12, weight: .medium))
                                    Text(team.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(
                                        .secondary)
                                }
                                Spacer()
                            }.padding(12).background(
                                Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityLabel("Use team \(team.name), \(team.id)")
                    }
                    note(
                        "Suggested from installed Developer ID signing certificates. Confirm this is the team you want to monitor."
                    )
                }
            }
            if let note = flow.discoveryNote { self.note(note) }
            instruction(
                "1", "Check Membership details",
                "Sign in to Apple Developer, open Membership details, and copy Team ID. You can enter a different team below."
            )
            externalLink("Open Membership details", "https://developer.apple.com/account/")
            VStack(alignment: .leading, spacing: 8) {
                Text("Team ID").font(.system(size: 12, weight: .medium))
                TextField("10 letters and numbers", text: $flow.teamID).textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .team).onSubmit { flow.advance() }.accessibilityLabel("Team ID")
            }
        }
    }

    private var passwordStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            intro(
                "Create a password just for Notary Watch. Keep it ready for the next step, where you’ll paste it directly into Apple’s secure Terminal prompt."
            )
            instruction(
                "1", "Open your Apple Account", "Sign in with the same email you entered: \(flow.details.email)")
            externalLink("Open Apple Account", "https://account.apple.com/")
            instruction(
                "2", "Choose Sign-In and Security",
                "Open App-Specific Passwords, choose Generate an app-specific password, and give it the name Notary Watch. Two-factor authentication must be enabled on your Apple account."
            )
            instruction(
                "3", "Keep the generated password ready",
                "Keep Apple’s page open or copy the generated password. Use it instead of your normal Apple account password."
            )
            Toggle("I have my generated app-specific password ready", isOn: $flow.hasPassword)
                .font(.system(size: 12)).toggleStyle(.checkbox)
            note(
                "Notary Watch never reads or stores this password. You’ll paste it into Apple’s tool in the next step.")
        }
    }

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            intro(
                "We’ve filled in your account and team. Apple’s Terminal prompt will ask only for the app-specific password you just generated."
            )
            profileLabelField
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 9) {
                GridRow {
                    Text("Apple account").foregroundStyle(.secondary)
                    Text(flow.details.email).textSelection(.enabled)
                }
                GridRow {
                    Text("Team ID").foregroundStyle(.secondary)
                    Text(flow.details.teamID).monospaced().textSelection(.enabled)
                }
            }.font(.system(size: 12))
            VStack(alignment: .leading, spacing: 7) {
                Text("Save as Keychain profile").font(.system(size: 12, weight: .medium))
                TextField("notary-watch", text: $flow.profileName).textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .profile).accessibilityLabel("Keychain profile name")
                note(
                    "Apple will save or update this profile in Keychain. No need to select an API key or enter your team again."
                )
            }
            HStack(spacing: 12) {
                Button(flow.terminalOpened ? "Reopen Terminal prompt" : "Open Terminal prompt") { openTerminal() }
                    .disabled(busy || !flow.details.isValid).accessibilityLabel("Open Terminal prompt")
                Button(commandCopied ? "Command copied" : "Copy command") {
                    do {
                        copyToClipboard(try flow.details.terminalCommand())
                        commandCopied = true
                    } catch { flow.error = error.localizedDescription }
                }.buttonStyle(.link).disabled(busy || !flow.details.isValid)
            }
            instruction(
                "1", "Paste the generated password in Terminal",
                "Press Return after pasting. The characters stay hidden while you type. Wait for Apple to confirm that the credentials were saved."
            )
            instruction(
                "2", "Return here and check the connection",
                "Click Check connection below. We’ll request your real submission history from Apple before finishing setup."
            )
            if flow.terminalOpened {
                Label("Terminal opened. This does not yet mean your credentials are saved.", systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var existingProfileForm: some View {
        VStack(alignment: .leading, spacing: 20) {
            intro(
                "Already using notarytool? Enter the Keychain profile name from your notarization workflow and we’ll check it with Apple."
            )
            profileLabelField
            VStack(alignment: .leading, spacing: 8) {
                Text("Keychain profile name").font(.system(size: 12, weight: .medium))
                TextField("notary-watch", text: $flow.profileName).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Keychain profile name").onSubmit { verify() }
            }
            DisclosureGroup("Custom Keychain (optional)", isExpanded: $showCustomKeychain) {
                HStack {
                    TextField("Default data protection Keychain", text: $flow.keychainPath).textFieldStyle(
                        .roundedBorder
                    ).accessibilityLabel("Custom Keychain path")
                    Button("Choose…") { chooseKeychain() }
                }.padding(.top, 10)
            }.font(.system(size: 12))
            note("Credentials stay in Keychain. The app remembers the profile name and optional Keychain path.")
            Button("Help me create a new profile instead") {
                existingProfile = false
                flow.startNewProfile()
                operation = Task { await flow.checkMac() }
            }.buttonStyle(.link).disabled(busy)
        }
    }

    private var completion: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("Apple verified your connection", systemImage: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.accent)
            intro(
                flow.connectedCount == 0
                    ? "Your profile is ready. Apple returned no recent submissions for this team; new activity will appear in the dashboard."
                    : "We loaded \(flow.connectedCount) recent \(flow.connectedCount == 1 ? "submission" : "submissions") from Apple. Your dashboard is ready."
            )
            Text("Saved as \(model.activeProfile?.displayName ?? flow.profileName)")
                .font(.system(size: 13, weight: .medium))
            Text("Keychain profile: \(flow.profileName)").font(.system(size: 12)).foregroundStyle(.secondary)
            note(
                "Use the sidebar to find requests still processing or needing attention. Automatic refresh follows new results while the window is active."
            )
        }
    }

    private var profileLabelField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Name in Notary Watch (optional)").font(.system(size: 12, weight: .medium))
            TextField("Personal, Work, or a team name", text: $flow.displayName).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Profile display name")
            note("A friendly name for the profile switcher. Your Keychain profile name stays the same.")
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if flow.step != .complete {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                if !existingProfile && flow.step != .tools { Button("Back") { flow.back() }.disabled(busy) }
            }
            if flow.isBusy || openingTerminal {
                ProgressView().controlSize(.small)
                Text(
                    openingTerminal
                        ? "Opening Terminal…"
                        : !existingProfile && flow.step == .tools ? "Checking your Mac…" : "Checking with Apple…"
                )
                .font(.system(size: 11)).foregroundStyle(.secondary)
                if operation != nil { Button("Cancel") { operation?.cancel() }.controlSize(.small) }
            }
            Spacer(minLength: 0)
            if flow.step == .complete {
                Button("Show submissions") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(
                    .defaultAction)
            } else if existingProfile || flow.step == .connect {
                Button("Check connection") { verify() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(busy || !flow.details.profileIsValid || (!existingProfile && !flow.details.isValid))
            } else {
                Button("Continue") { flow.advance() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(busy || !flow.canContinue)
            }
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }

    private func intro(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(
            horizontal: false, vertical: true)
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(
            horizontal: false, vertical: true)
    }
    private func instruction(_ number: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accent)
                .frame(width: 22, height: 22).background(Palette.accent.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                note(text)
            }
        }
    }
    @ViewBuilder private func externalLink(_ title: String, _ address: String) -> some View {
        if let url = URL(string: address) {
            Link(destination: url) { Label(title, systemImage: "arrow.up.right") }.font(.system(size: 12))
                .accessibilityLabel(title)
        }
    }
    private func verify() {
        guard !busy else { return }
        focusedField = nil
        operation = Task { await flow.verify(using: model, existingProfile: existingProfile) }
    }
    private func openTerminal() {
        guard !busy else { return }
        openingTerminal = true
        flow.error = nil
        operation = Task {
            defer { openingTerminal = false }
            do {
                try await SetupTerminal.open(details: flow.details)
                flow.terminalOpened = true
            } catch {
                flow.error =
                    "Couldn’t open Terminal. \(error.localizedDescription) You can copy the command and paste it into Terminal instead."
            }
        }
    }
    private func chooseKeychain() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the Keychain file used when storing this notarytool profile."
        if panel.runModal() == .OK, let url = panel.url { flow.keychainPath = url.path }
    }
}
