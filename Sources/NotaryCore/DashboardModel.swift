import Combine
import Foundation

@MainActor
public final class DashboardModel: ObservableObject {
    @Published public private(set) var submissions: [Submission] = []
    @Published public private(set) var savedProfiles: [SavedNotaryProfile] = []
    @Published public private(set) var activeProfileID: UUID?
    @Published public private(set) var profileStorageError: String?
    @Published public private(set) var isSample: Bool
    @Published public private(set) var isBusy = false
    @Published public private(set) var activity = ""
    @Published public private(set) var lastRefresh: Date?
    @Published public var lastError: String?
    @Published public var filter: SubmissionFilter = .all
    @Published public var search = ""
    @Published public var selectedID: UUID? {
        didSet {
            if oldValue != selectedID {
                log = nil
                logText = nil
                logID = nil
            }
        }
    }
    @Published public private(set) var log: NotaryLog?
    @Published public private(set) var logText: String?
    private var logID: UUID?
    @Published public var autoRefresh: Bool {
        didSet { defaults.set(autoRefresh, forKey: "autoRefresh") }
    }

    private let client: any NotaryServing
    private let defaults: UserDefaults
    private let profileStore: ProfileStore
    private var catalog = ProfileCatalog()

    public init(client: any NotaryServing = NotaryClient(), defaults: UserDefaults = .standard, sample: Bool = false) {
        self.client = client
        self.defaults = defaults
        self.profileStore = ProfileStore(defaults: defaults)
        self.isSample = sample
        self.autoRefresh = defaults.object(forKey: "autoRefresh") == nil ? true : defaults.bool(forKey: "autoRefresh")
        do {
            let loaded = try profileStore.load()
            catalog = loaded
            savedProfiles = loaded.profiles
            activeProfileID = loaded.activeProfileID
        } catch {
            profileStorageError = error.localizedDescription
            lastError = error.localizedDescription
        }
        if sample {
            submissions = SampleData.submissions()
            selectedID = submissions.first?.id
        }
    }

    public var visibleSubmissions: [Submission] { filter.apply(to: submissions, search: search) }
    public var selected: Submission? { submissions.first { $0.id == selectedID } }
    public var isConnected: Bool { !isSample && profile != nil }
    public var activeProfile: SavedNotaryProfile? { savedProfiles.first { $0.id == activeProfileID } }
    public var profile: NotaryProfile? { activeProfile?.credentials }

    public func count(_ filter: SubmissionFilter) -> Int { submissions.filter(filter.includes).count }

    @discardableResult
    public func connect(_ candidate: NotaryProfile, displayName: String? = nil) async -> Bool {
        guard !isBusy, canChangeProfiles else { return false }
        begin("Connecting to Apple…")
        defer { isBusy = false }
        do {
            var updated = catalog
            try updated.remember(candidate, displayName: displayName)
            let history = try await client.history(profile: candidate)
            try Task.checkCancellation()
            try profileStore.save(updated)
            applyCatalog(updated)
            isSample = false
            clearHistory()
            replaceHistory(history)
            return true
        } catch is CancellationError { return false } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func activateProfile(_ id: UUID) async -> Bool {
        guard !isBusy, canChangeProfiles else { return false }
        guard let saved = savedProfiles.first(where: { $0.id == id }) else {
            lastError = ProfileStorageError.missingProfile.localizedDescription
            return false
        }
        if id == activeProfileID && !isSample {
            await refresh()
            return lastError == nil
        }
        let connected = await connect(saved.credentials)
        if !connected, let error = lastError { lastError = "Couldn’t switch to \(saved.displayName). \(error)" }
        return connected
    }

    @discardableResult
    public func renameProfile(_ id: UUID, to name: String) -> Bool {
        guard !isBusy, canChangeProfiles else { return false }
        do {
            var updated = catalog
            try updated.rename(id, to: name)
            try profileStore.save(updated)
            applyCatalog(updated)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func removeProfile(_ id: UUID) async -> Bool {
        guard !isBusy, canChangeProfiles else { return false }
        do {
            var updated = catalog
            try updated.remove(id)
            try profileStore.save(updated)
            let removedActive = activeProfileID == id
            applyCatalog(updated)
            if removedActive && !isSample {
                clearHistory()
                await refresh()
            }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    public func refresh() async {
        guard !isBusy, !isSample, let profile else { return }
        begin("Refreshing history…")
        defer { isBusy = false }
        do {
            let history = try await client.history(profile: profile)
            try Task.checkCancellation()
            replaceHistory(history)
        } catch is CancellationError {} catch {
            lastError = error.localizedDescription
        }
    }

    public func checkSelected() async {
        guard !isBusy, !isSample, let profile, let id = selectedID else { return }
        begin("Checking submission…")
        defer { isBusy = false }
        do {
            let value = try await client.info(id: id, profile: profile)
            try Task.checkCancellation()
            if let index = submissions.firstIndex(where: { $0.id == id }) { submissions[index] = value }
            reconcileSelection()
            // A single-submission check does not claim that the full history was refreshed.
        } catch is CancellationError {} catch { lastError = error.localizedDescription }
    }

    public func loadLog() async {
        guard !isBusy, let submission = selected, submission.state.isFinished else { return }
        begin("Fetching Apple log…")
        defer { isBusy = false }
        do {
            let result: (NotaryLog, String)
            if isSample {
                result = try SampleData.log(for: submission)
            } else if let profile {
                result = try await client.log(id: submission.id, profile: profile)
            } else {
                throw NotaryError.invalidProfile
            }
            try Task.checkCancellation()
            guard selectedID == submission.id else { return }
            log = result.0
            logText = result.1
            logID = submission.id
        } catch is CancellationError {} catch { lastError = error.localizedDescription }
    }

    public func showSamples() {
        guard !isBusy else { return }
        isSample = true
        lastError = nil
        lastRefresh = nil
        filter = .all
        search = ""
        selectedID = nil
        submissions = SampleData.submissions()
        selectedID = submissions.first?.id
    }

    public func leaveSamples() async {
        guard !isBusy else { return }
        isSample = false
        clearHistory()
        await refresh()
    }

    private var canChangeProfiles: Bool {
        if let profileStorageError {
            lastError = profileStorageError
            return false
        }
        return true
    }

    private func applyCatalog(_ updated: ProfileCatalog) {
        catalog = updated
        savedProfiles = updated.profiles
        activeProfileID = updated.activeProfileID
    }

    private func clearHistory() {
        submissions = []
        selectedID = nil
        log = nil
        logText = nil
        logID = nil
        lastRefresh = nil
        lastError = nil
        filter = .all
        search = ""
    }

    private func begin(_ activity: String) {
        isBusy = true
        self.activity = activity
        lastError = nil
    }

    private func replaceHistory(_ history: [Submission]) {
        submissions = history
        lastRefresh = .now
        reconcileSelection()
        if let logID, let current = history.first(where: { $0.id == logID }), current.status != log?.status {
            log = nil
            logText = nil
            self.logID = nil
        }
    }

    private func reconcileSelection() {
        if !visibleSubmissions.contains(where: { $0.id == selectedID }) {
            selectedID = visibleSubmissions.first?.id
        }
    }
}
