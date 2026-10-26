import Combine
import Foundation

public enum SetupStep: Int, CaseIterable, Identifiable, Sendable {
    case tools, account, team, password, connect, complete
    public var id: Self { self }
    public var title: String {
        switch self {
        case .tools: "Check your Mac"
        case .account: "Find your Apple account"
        case .team: "Choose your developer team"
        case .password: "Create an app password"
        case .connect: "Save and connect"
        case .complete: "You’re connected"
        }
    }
}

public struct DeveloperTeam: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public static func parseSigningIdentities(_ text: String) throws -> [DeveloperTeam] {
        let regex = try NSRegularExpression(
            pattern: #""Developer ID (?:Application|Installer): (.+) \(([A-Z0-9]{10})\)""#)
        var teams: [DeveloperTeam] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let nameRange = Range(match.range(at: 1), in: text), let idRange = Range(match.range(at: 2), in: text)
            else { continue }
            let id = String(text[idRange])
            if !teams.contains(where: { $0.id == id }) {
                teams.append(DeveloperTeam(id: id, name: String(text[nameRange])))
            }
        }
        return teams
    }
}

public struct SetupDetails: Equatable, Sendable {
    public let email: String
    public let teamID: String
    public let profileName: String

    public init(email: String, teamID: String, profileName: String) {
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        self.teamID = teamID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.profileName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var emailIsValid: Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasPrefix(".")
            && !parts[1].hasSuffix(".")
            && email.count <= 254 && !email.contains(where: { $0.isWhitespace || $0.isNewline })
            && !email.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    public var teamIsValid: Bool {
        teamID.utf8.count == 10 && teamID.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) }
    }
    public var profileIsValid: Bool {
        !profileName.isEmpty && !profileName.hasPrefix("-") && profileName.count <= 128
            && !profileName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    public var isValid: Bool { emailIsValid && teamIsValid && profileIsValid }

    /// Contains no password. Supplying account and team skips Apple's API-key prompts.
    public func terminalCommand() throws -> String {
        guard isValid else { throw SetupError.invalidDetails }
        return
            "/usr/bin/xcrun notarytool store-credentials \(Self.shellQuote(profileName)) --apple-id \(Self.shellQuote(email)) --team-id \(Self.shellQuote(teamID))"
    }

    /// The secret is entered directly into Apple's tool, never through this script or app.
    public func terminalScript() throws -> String {
        let command = try terminalCommand()
        return """
            #!/bin/zsh
            trap '/bin/rm -f -- "$0"; /bin/rmdir -- "${0:h}" 2>/dev/null' EXIT
            printf '\\nNotary Watch: save your credentials\\n\\n'
            printf 'Paste the app-specific password when Apple asks. Characters stay hidden.\\n'
            printf 'This saves or updates the Keychain profile you chose in Notary Watch.\\n\\n'
            \(command)
            notary_exit_status=$?
            if (( notary_exit_status == 0 )); then
                printf '\\nSaved. Return to Notary Watch and click Check connection.\\n'
            else
                printf '\\nApple could not save these credentials. Check the error above.\\n'
                printf 'Return to Notary Watch to correct your account or team, then try again.\\n'
            fi
            exit "$notary_exit_status"

            """
    }
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum SetupError: LocalizedError {
    case invalidDetails, terminalUnavailable
    public var errorDescription: String? {
        switch self {
        case .invalidDetails: "Enter a valid Apple account email, 10-character Team ID, and profile name."
        case .terminalUnavailable: "Terminal could not be opened. Copy the command and run it in Terminal instead."
        }
    }
}

public protocol SetupInspecting: Sendable {
    func checkTools() async throws -> String
    func findTeams() async throws -> [DeveloperTeam]
}

public struct MacSetupInspector: SetupInspecting {
    private let tools: any CommandRunning
    private let identities: any CommandRunning
    public init(
        tools: any CommandRunning = NotaryCommandRunner(),
        identities: any CommandRunning = NotaryCommandRunner(
            executable: URL(fileURLWithPath: "/usr/bin/security"), prefix: [])
    ) {
        self.tools = tools
        self.identities = identities
    }
    public func checkTools() async throws -> String {
        let data = try await tools.run(arguments: ["--version"])
        let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else { throw NotaryError.invalidResponse("notarytool did not report its version.") }
        return version
    }
    public func findTeams() async throws -> [DeveloperTeam] {
        let data = try await identities.run(arguments: ["find-identity", "-v", "-p", "codesigning"])
        return try DeveloperTeam.parseSigningIdentities(String(decoding: data, as: UTF8.self))
    }
}

@MainActor
public final class SetupFlow: ObservableObject {
    @Published public private(set) var step: SetupStep = .tools
    @Published public var email = "" {
        didSet {
            if oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
                != email.trimmingCharacters(in: .whitespacesAndNewlines)
            {
                hasPassword = false
                terminalOpened = false
            }
        }
    }
    @Published public var teamID = "" {
        didSet { if oldValue != teamID { terminalOpened = false } }
    }
    @Published public var profileName = "notary-watch" {
        didSet { if oldValue != profileName { terminalOpened = false } }
    }
    @Published public var keychainPath = ""
    @Published public var displayName = ""
    @Published public var hasPassword = false
    @Published public var error: String?
    @Published public private(set) var toolsVersion: String?
    @Published public private(set) var teams: [DeveloperTeam] = []
    @Published public private(set) var discoveryNote: String?
    @Published public private(set) var isBusy = false
    @Published public private(set) var connectedCount = 0
    @Published public var terminalOpened = false
    private let inspector: any SetupInspecting

    public init(inspector: any SetupInspecting = MacSetupInspector(), profile: NotaryProfile? = nil) {
        self.inspector = inspector
        if let profile {
            profileName = profile.name
            keychainPath = profile.keychainPath
        } else {
            profileName = "notary-watch-\(UUID().uuidString.prefix(8).lowercased())"
        }
    }
    public var details: SetupDetails { SetupDetails(email: email, teamID: teamID, profileName: profileName) }
    public var canContinue: Bool {
        guard !isBusy else { return false }
        switch step {
        case .tools: return toolsVersion != nil
        case .account: return details.emailIsValid
        case .team: return details.teamIsValid
        case .password: return hasPassword
        case .connect, .complete: return false
        }
    }

    public func checkMac() async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        toolsVersion = nil
        teams = []
        discoveryNote = nil
        defer { isBusy = false }
        do {
            let version = try await inspector.checkTools()
            try Task.checkCancellation()
            toolsVersion = version
            do {
                let found = try await inspector.findTeams()
                try Task.checkCancellation()
                teams = found
                discoveryNote = nil
                if found.count == 1, teamID.isEmpty { teamID = found[0].id }
            } catch is CancellationError { return } catch {
                discoveryNote =
                    "Couldn’t read installed signing certificates. You can enter your Team ID from Apple Developer instead."
            }
        } catch is CancellationError {} catch {
            self.error =
                "Apple’s notarization tool isn’t ready. Install and open Xcode, then select it in Xcode → Settings → Locations → Command Line Tools. \(error.localizedDescription)"
        }
    }
    public func advance() {
        guard canContinue, let next = SetupStep(rawValue: step.rawValue + 1) else { return }
        email = details.email
        teamID = details.teamID
        error = nil
        step = next
    }
    public func back() {
        guard !isBusy, step != .complete, let previous = SetupStep(rawValue: step.rawValue - 1) else { return }
        error = nil
        terminalOpened = false
        step = previous
    }

    public func startNewProfile() {
        guard !isBusy else { return }
        step = .tools
        error = nil
        terminalOpened = false
        hasPassword = false
        toolsVersion = nil
        teams = []
        discoveryNote = nil
        keychainPath = ""
        displayName = ""
        profileName = "notary-watch-\(UUID().uuidString.prefix(8).lowercased())"
    }
    public func verify(using dashboard: DashboardModel, existingProfile: Bool = false) async {
        guard !isBusy, !dashboard.isBusy else {
            error = "Another request is running. Try again when it finishes."
            return
        }
        guard details.profileIsValid, existingProfile || (step == .connect && details.isValid && hasPassword) else {
            error = SetupError.invalidDetails.localizedDescription
            return
        }
        isBusy = true
        error = nil
        defer { isBusy = false }
        let profile = NotaryProfile(name: profileName, keychainPath: existingProfile ? keychainPath : "")
        let label = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if await dashboard.connect(profile, displayName: label.isEmpty ? nil : label) {
            connectedCount = dashboard.submissions.count
            step = .complete
        } else if !Task.isCancelled {
            error =
                dashboard.lastError
                ?? "The connection wasn’t completed. Finish saving your credentials in Terminal, then try again."
        }
    }
}
