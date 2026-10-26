import Foundation
import Testing

@testable import NotaryCore

struct SetupDetailsTests {
    @Test func findsDistinctDeveloperTeamsWithoutGuessingAccountEmails() throws {
        let text = """
              1) ABC "Developer ID Application: Example Person (AB12CD34E5)"
              2) DEF "Developer ID Installer: Example Person (AB12CD34E5)"
              3) 123 "Apple Development: Other Person (ZZ12YY34X5)"
              4) 456 "Developer ID Application: Example Org (XY12ZA34B5)"
            """
        let teams = try DeveloperTeam.parseSigningIdentities(text)
        #expect(
            teams == [
                DeveloperTeam(id: "AB12CD34E5", name: "Example Person"),
                DeveloperTeam(id: "XY12ZA34B5", name: "Example Org"),
            ])
        #expect(try DeveloperTeam.parseSigningIdentities("0 valid identities found").isEmpty)
    }

    @Test func validatesAndNormalizesUserDetails() {
        let details = SetupDetails(email: "  someone@example.com ", teamID: " ab12cd34e5 ", profileName: " My Notary ")
        #expect(details.isValid)
        #expect(details.teamID == "AB12CD34E5")
        #expect(details.profileName == "My Notary")
        for email in ["", "person", "person@", "@example.com", "a@b@c.com", "bad\n@example.com", "someone@.com"] {
            #expect(!SetupDetails(email: email, teamID: details.teamID, profileName: "test").emailIsValid)
        }
        for team in ["123", "AB12-CD34E", "ＡＢ12CD34E5", "AB12CD34E5F"] {
            #expect(!SetupDetails(email: details.email, teamID: team, profileName: "test").teamIsValid)
        }
        #expect(!SetupDetails(email: details.email, teamID: details.teamID, profileName: "--help").profileIsValid)
        #expect(!SetupDetails(email: details.email, teamID: details.teamID, profileName: "bad\nname").profileIsValid)
    }

    @Test func commandSkipsAPIKeyPromptsAndContainsNoPasswordArgument() throws {
        let details = SetupDetails(email: "you@example.com", teamID: "AB12CD34E5", profileName: "profile")
        let command = try details.terminalCommand()
        #expect(
            command
                == "/usr/bin/xcrun notarytool store-credentials 'profile' --apple-id 'you@example.com' --team-id 'AB12CD34E5'"
        )
        #expect(!command.contains("--password"))
        #expect(!command.contains("--no-validate"))
        #expect(throws: SetupError.self) {
            try SetupDetails(email: "", teamID: "", profileName: "").terminalCommand()
        }
    }

    @Test func shellMetacharactersRemainLiteral() async throws {
        let hostile = "a'b; $(printf INJECTED) `printf OTHER` & \"quote\""
        let runner = NotaryCommandRunner(executable: URL(fileURLWithPath: "/bin/zsh"), prefix: ["-c"])
        let output = try await runner.run(arguments: ["printf '%s' " + SetupDetails.shellQuote(hostile)])
        #expect(String(decoding: output, as: UTF8.self) == hostile)
    }

    @Test func generatedTerminalScriptHasValidZshSyntaxAndCleansUp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Save credentials.command")
        let details = SetupDetails(
            email: "test@example.com", teamID: "AB12CD34E5", profileName: "My 'quoted' profile"
        )
        let script = try details.terminalScript()
        try script.write(to: url, atomically: true, encoding: .utf8)
        let runner = NotaryCommandRunner(executable: URL(fileURLWithPath: "/bin/zsh"), prefix: [])
        _ = try await runner.run(arguments: ["-n", url.path])
        #expect(script.contains("trap '"))
        #expect(script.contains("exit \"$notary_exit_status\""))
        #expect(script.contains("Check connection"))
        #expect(!script.contains("--password"))
        // Execute only the wrapper with a local success fixture, never Apple's credential operation.
        let fixture = script.replacingOccurrences(of: try details.terminalCommand(), with: "/usr/bin/true")
        try fixture.write(to: url, atomically: true, encoding: .utf8)
        let result = try await runner.run(arguments: [url.path])
        #expect(String(decoding: result, as: UTF8.self).contains("Saved. Return to Notary Watch"))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}

struct StubInspector: SetupInspecting {
    var ready = true
    var teams: [DeveloperTeam] = [DeveloperTeam(id: "AB12CD34E5", name: "Example Person")]
    var failDiscovery = false
    func checkTools() async throws -> String {
        if !ready { throw NotaryError.commandFailed(1, "Xcode unavailable") }
        return "1.2 test version"
    }
    func findTeams() async throws -> [DeveloperTeam] {
        if failDiscovery { throw NotaryError.commandFailed(1, "Keychain unavailable") }
        return teams
    }
}

@MainActor
struct SetupFlowTests {
    @Test func wizardGatesEachStepAndPreservesInputsWhenGoingBack() async {
        let flow = SetupFlow(inspector: StubInspector())
        flow.advance()
        #expect(flow.step == .tools)
        await flow.checkMac()
        #expect(flow.canContinue)
        flow.advance()
        #expect(flow.step == .account)
        #expect(!flow.canContinue)
        flow.email = "test@example.com"
        flow.advance()
        #expect(flow.step == .team)
        #expect(flow.teamID == "AB12CD34E5")
        flow.teamID = "invalid"
        #expect(!flow.canContinue)
        flow.teamID = "AB12CD34E5"
        flow.advance()
        #expect(flow.step == .password)
        #expect(!flow.canContinue)
        flow.hasPassword = true
        flow.advance()
        #expect(flow.step == .connect)
        flow.back()
        #expect(flow.step == .password)
        #expect(flow.hasPassword)
        #expect(flow.email == "test@example.com")
    }

    @Test func missingXcodeBlocksAdvanceWithRecoveryInstructions() async {
        let flow = SetupFlow(inspector: StubInspector(ready: false))
        await flow.checkMac()
        #expect(!flow.canContinue)
        #expect(flow.toolsVersion == nil)
        #expect(flow.error?.contains("Locations") == true)
        #expect(!flow.isBusy)
    }

    @Test func certificateDiscoveryFailureAllowsManualTeamEntry() async {
        let flow = SetupFlow(inspector: StubInspector(failDiscovery: true))
        await flow.checkMac()
        #expect(flow.canContinue)
        #expect(flow.teamID.isEmpty)
        #expect(flow.discoveryNote != nil)
        #expect(flow.error == nil)
    }

    @Test func multipleTeamsAreNotAutomaticallySelected() async {
        let flow = SetupFlow(
            inspector: StubInspector(teams: [
                DeveloperTeam(id: "AB12CD34E5", name: "One"), DeveloperTeam(id: "XY12ZA34B5", name: "Two"),
            ]))
        await flow.checkMac()
        #expect(flow.teamID.isEmpty)
        #expect(flow.teams.count == 2)
    }

    @Test func creatingNewProfileDoesNotReuseExistingProfileNameOrKeychain() {
        let flow = SetupFlow(profile: NotaryProfile(name: "existing", keychainPath: "/some/ci.keychain-db"))
        flow.startNewProfile()
        #expect(flow.profileName.hasPrefix("notary-watch-"))
        #expect(flow.keychainPath.isEmpty)
        #expect(flow.step == .tools)
        #expect(SetupFlow().profileName != SetupFlow().profileName)
    }

    @Test func changingAccountRequiresANewPasswordConfirmation() {
        let flow = SetupFlow()
        flow.email = "first@example.com"
        flow.hasPassword = true
        flow.terminalOpened = true
        flow.email = "second@example.com"
        #expect(!flow.hasPassword)
        #expect(!flow.terminalOpened)
    }

    @Test func successfulConnectionRequiresRealClientResultAndPopulatesDashboard() async throws {
        let suite = "Setup.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ControlledService()
        let model = DashboardModel(client: service, defaults: defaults, sample: true)
        let flow = SetupFlow(inspector: StubInspector())
        await flow.checkMac()
        flow.advance()
        flow.email = "test@example.com"
        flow.advance()
        flow.advance()
        flow.hasPassword = true
        flow.advance()
        flow.terminalOpened = true
        #expect(flow.step == .connect)
        await flow.verify(using: model)
        #expect(flow.step == .complete)
        #expect(flow.connectedCount == 8)
        #expect(!model.isSample)
        #expect(defaults.string(forKey: "profile") == flow.profileName)
    }

    @Test func failedVerificationDoesNotFinishWizardOrReplacePreviousProfile() async throws {
        let suite = "Setup.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ControlledService()
        let model = DashboardModel(client: service, defaults: defaults)
        #expect(await model.connect(NotaryProfile(name: "working")))
        await service.setFailure(true)
        let flow = SetupFlow(profile: NotaryProfile(name: "missing"))
        await flow.verify(using: model, existingProfile: true)
        #expect(flow.step != .complete)
        #expect(flow.error?.contains("Offline") == true)
        #expect(model.profile?.name == "working")
        #expect(!flow.isBusy)
    }

    @Test func existingProfileShortcutHandlesEmptyHistoryWithoutCollectingAccountDetails() async throws {
        let suite = "Setup.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ControlledService()
        await service.setHistory([])
        let model = DashboardModel(client: service, defaults: defaults)
        let profile = NotaryProfile(name: "existing", keychainPath: "/some/custom.keychain-db")
        let flow = SetupFlow(profile: profile)
        await flow.verify(using: model, existingProfile: true)
        #expect(flow.step == .complete)
        #expect(flow.connectedCount == 0)
        #expect(model.profile == profile)
        #expect(flow.email.isEmpty)
        #expect(!flow.hasPassword)
    }

    @Test func setupAddsNamedProfilesWithoutReplacingPreviousConnections() async throws {
        let suite = "Setup.profiles.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DashboardModel(client: ControlledService(), defaults: defaults)
        #expect(await model.connect(NotaryProfile(name: "personal-keychain"), displayName: "Personal"))
        let personalID = try #require(model.activeProfileID)
        let flow = SetupFlow(profile: NotaryProfile(name: "work-keychain"))
        flow.displayName = "Work"
        await flow.verify(using: model, existingProfile: true)
        #expect(flow.step == .complete)
        #expect(model.savedProfiles.count == 2)
        #expect(model.activeProfile?.displayName == "Work")
        #expect(model.savedProfiles.first(where: { $0.id == personalID })?.displayName == "Personal")
    }
}
