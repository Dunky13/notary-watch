import Foundation
import Testing

@testable import NotaryCore

@MainActor
struct ProfilePersistenceTests {
    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let name = "Profiles.tests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func migratesLegacyProfileWithCustomKeychainExactlyOnce() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy-notary", forKey: "profile")
        defaults.set("/custom/ci.keychain-db", forKey: "keychainPath")
        let store = ProfileStore(defaults: defaults)
        let migrated = try store.load()
        #expect(migrated.profiles.count == 1)
        #expect(
            migrated.active?.credentials == NotaryProfile(name: "legacy-notary", keychainPath: "/custom/ci.keychain-db")
        )
        #expect(try store.load() == migrated)
        #expect(defaults.data(forKey: ProfileStore.key) != nil)
    }

    @Test func savedProfilesAndActiveSelectionSurviveRestart() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DashboardModel(client: ControlledService(), defaults: defaults)
        #expect(await model.connect(NotaryProfile(name: "personal"), displayName: "Personal"))
        let firstID = try #require(model.activeProfileID)
        #expect(await model.connect(NotaryProfile(name: "work"), displayName: "Work"))
        #expect(await model.activateProfile(firstID))
        let restored = DashboardModel(client: ControlledService(), defaults: defaults)
        #expect(restored.savedProfiles.count == 2)
        #expect(restored.activeProfile?.displayName == "Personal")
        #expect(restored.activeProfileID == firstID)
        #expect(restored.submissions.isEmpty)
    }

    @Test func sameCredentialReferenceDoesNotCreateDuplicatesOrLoseRenames() throws {
        var catalog = ProfileCatalog()
        let reference = NotaryProfile(name: "same")
        try catalog.remember(reference, displayName: "Personal")
        let id = try #require(catalog.activeProfileID)
        try catalog.remember(reference)
        #expect(catalog.profiles.count == 1)
        #expect(catalog.active?.id == id)
        #expect(catalog.active?.displayName == "Personal")
        try catalog.remember(NotaryProfile(name: "same", keychainPath: "/custom/ci.keychain-db"), displayName: "CI")
        #expect(catalog.profiles.count == 2)
    }

    @Test func corruptCatalogIsPreservedAndCannotBeOverwrittenByConnecting() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let corrupt = Data("{not valid json}".utf8)
        defaults.set(corrupt, forKey: ProfileStore.key)
        defaults.set("old-single-profile", forKey: "profile")
        let model = DashboardModel(client: ControlledService(), defaults: defaults)
        #expect(model.profileStorageError != nil)
        #expect(model.profile == nil)
        #expect(await !model.connect(NotaryProfile(name: "new")))
        #expect(defaults.data(forKey: ProfileStore.key) == corrupt)
        #expect(defaults.string(forKey: "profile") == "old-single-profile")
    }

    @Test func unsupportedOrInconsistentCatalogsFailValidation() throws {
        for json in [
            #"{"version":2,"profiles":[]}"#,
            #"{"version":1,"profiles":[],"activeProfileID":"A1B2C3D4-0000-4000-8000-000000000000"}"#,
            #"{"version":1,"profiles":[{"id":"A1B2C3D4-0000-4000-8000-000000000000","displayName":"One","credentials":{"name":"one","keychainPath":""}}]}"#,
        ] {
            let decoded = try JSONDecoder().decode(ProfileCatalog.self, from: Data(json.utf8))
            #expect(throws: ProfileStorageError.self) { try decoded.validate() }
        }
    }

    @Test func removingLastProfileDoesNotResurrectLegacySettings() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy", forKey: "profile")
        let model = DashboardModel(client: ControlledService(), defaults: defaults)
        let id = try #require(model.activeProfileID)
        #expect(await model.removeProfile(id))
        #expect(model.profile == nil)
        #expect(model.submissions.isEmpty)
        #expect(defaults.string(forKey: "profile") == nil)
        // Even a stale value from an older app version cannot override the explicit empty catalog.
        defaults.set("legacy", forKey: "profile")
        let restored = DashboardModel(client: ControlledService(), defaults: defaults)
        #expect(restored.savedProfiles.isEmpty)
        #expect(restored.profile == nil)
    }

    @Test func renameChangesOnlyAppLabelAndRejectsInvalidNames() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DashboardModel(client: ControlledService(), defaults: defaults)
        let reference = NotaryProfile(name: "machine-profile", keychainPath: "/custom/notary.keychain-db")
        #expect(await model.connect(reference))
        let id = try #require(model.activeProfileID)
        let timestamp = model.lastRefresh
        #expect(model.renameProfile(id, to: "  Work  "))
        #expect(model.profile == reference)
        #expect(model.activeProfile?.displayName == "Work")
        #expect(model.lastRefresh == timestamp)
        #expect(!model.renameProfile(id, to: "\n\t"))
        #expect(model.activeProfile?.displayName == "Work")
        #expect(try ProfileStore(defaults: defaults).load().active?.displayName == "Work")
    }
}

actor ProfileService: NotaryServing {
    var failures: Set<String> = []
    var requests: [NotaryProfile] = []
    var delayNext = false
    let personal: Submission
    let work: Submission

    init() {
        let base = SampleData.submissions()[2]
        personal = Submission(id: base.id, name: "Personal.dmg", createdDate: base.createdDate, status: "Accepted")
        // Deliberately reuse the ID: state isolation must not depend on globally unique Apple IDs.
        work = Submission(id: base.id, name: "Work.dmg", createdDate: base.createdDate, status: "Accepted")
    }
    func fail(_ name: String) { failures.insert(name) }
    func delayNextRequest() { delayNext = true }
    func history(profile: NotaryProfile) async throws -> [Submission] {
        requests.append(profile)
        if delayNext {
            delayNext = false
            try await Task.sleep(for: .seconds(10))
        }
        if failures.contains(profile.name) { throw NotaryError.commandFailed(1, "Offline") }
        return [profile.name == "personal" ? personal : work]
    }
    func info(id: UUID, profile: NotaryProfile) async throws -> Submission {
        profile.name == "personal" ? personal : work
    }
    func log(id: UUID, profile: NotaryProfile) async throws -> (NotaryLog, String) {
        try SampleData.log(for: profile.name == "personal" ? personal : work)
    }
}

@MainActor
struct ProfileSwitchingTests {
    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let name = "Profiles.switching.tests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func successfulSwitchReplacesHistoryAndClearsLogsSearchAndFilters() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ProfileService()
        let model = DashboardModel(client: service, defaults: defaults)
        #expect(await model.connect(NotaryProfile(name: "personal"), displayName: "Personal"))
        let personalID = try #require(model.activeProfileID)
        await model.loadLog()
        #expect(model.log != nil)
        model.filter = .accepted
        model.search = "Personal"
        #expect(await model.connect(NotaryProfile(name: "work"), displayName: "Work"))
        #expect(model.submissions.first?.name == "Work.dmg")
        #expect(model.log == nil)
        #expect(model.logText == nil)
        #expect(model.filter == .all)
        #expect(model.search.isEmpty)
        #expect(model.savedProfiles.count == 2)
        #expect(await model.activateProfile(personalID))
        #expect(model.submissions.first?.name == "Personal.dmg")
        #expect(await service.requests.last?.name == "personal")
    }

    @Test func failedSavedProfileSwitchKeepsActiveProfileHistoryAndPreferences() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ProfileService()
        let model = DashboardModel(client: service, defaults: defaults)
        #expect(await model.connect(NotaryProfile(name: "personal")))
        let personalID = try #require(model.activeProfileID)
        #expect(await model.connect(NotaryProfile(name: "work")))
        let original = model.submissions
        let timestamp = model.lastRefresh
        await service.fail("personal")
        #expect(await !model.activateProfile(personalID))
        #expect(model.profile?.name == "work")
        #expect(model.submissions == original)
        #expect(model.lastRefresh == timestamp)
        #expect(model.lastError?.contains("Couldn’t switch") == true)
        #expect(try ProfileStore(defaults: defaults).load().active?.credentials.name == "work")
    }

    @Test func failedAdditionDoesNotSaveAnUnverifiedProfile() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ProfileService()
        let model = DashboardModel(client: service, defaults: defaults)
        #expect(await model.connect(NotaryProfile(name: "personal")))
        await service.fail("work")
        #expect(await !model.connect(NotaryProfile(name: "work"), displayName: "Work"))
        #expect(model.savedProfiles.count == 1)
        #expect(model.profile?.name == "personal")
    }

    @Test func cancelledConnectionDoesNotPersistNewProfile() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ProfileService()
        let model = DashboardModel(client: service, defaults: defaults)
        #expect(await model.connect(NotaryProfile(name: "personal")))
        await service.delayNextRequest()
        let request = Task { await model.connect(NotaryProfile(name: "work")) }
        for _ in 0..<100 {
            if model.isBusy { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        request.cancel()
        #expect(await !request.value)
        #expect(model.savedProfiles.count == 1)
        #expect(model.profile?.name == "personal")
        #expect(!model.isBusy)
    }

    @Test func removingActiveProfileCannotShowItsHistoryUnderAnotherProfile() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ProfileService()
        let model = DashboardModel(client: service, defaults: defaults)
        #expect(await model.connect(NotaryProfile(name: "personal")))
        #expect(await model.connect(NotaryProfile(name: "work")))
        let workID = try #require(model.activeProfileID)
        await service.fail("personal")
        #expect(await model.removeProfile(workID))
        #expect(model.profile?.name == "personal")
        #expect(model.submissions.isEmpty)
        #expect(model.lastRefresh == nil)
        #expect(model.log == nil)
        #expect(model.lastError?.contains("Offline") == true)
        #expect(model.savedProfiles.count == 1)
    }

    @Test func removingInactiveProfileKeepsActiveHistoryUntouched() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DashboardModel(client: ProfileService(), defaults: defaults)
        #expect(await model.connect(NotaryProfile(name: "personal")))
        let personalID = try #require(model.activeProfileID)
        #expect(await model.connect(NotaryProfile(name: "work")))
        let original = model.submissions
        let timestamp = model.lastRefresh
        #expect(await model.removeProfile(personalID))
        #expect(model.profile?.name == "work")
        #expect(model.submissions == original)
        #expect(model.lastRefresh == timestamp)
    }

    @Test func recheckingActiveProfilePreservesCurrentSearchAndSelection() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DashboardModel(client: ProfileService(), defaults: defaults)
        #expect(await model.connect(NotaryProfile(name: "personal")))
        let id = try #require(model.activeProfileID)
        model.filter = .accepted
        model.search = "Personal"
        let selection = model.selectedID
        #expect(await model.activateProfile(id))
        #expect(model.filter == .accepted)
        #expect(model.search == "Personal")
        #expect(model.selectedID == selection)
    }

    @Test func selectingSavedProfileLeavesSampleModeAndLoadsLiveClientResult() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DashboardModel(client: ProfileService(), defaults: defaults)
        #expect(await model.connect(NotaryProfile(name: "personal")))
        let id = try #require(model.activeProfileID)
        model.showSamples()
        #expect(model.isSample)
        #expect(await model.activateProfile(id))
        #expect(!model.isSample)
        #expect(model.submissions.map(\.name) == ["Personal.dmg"])
        #expect(model.savedProfiles.count == 1)
    }
}
