import Foundation
import Testing

@testable import NotaryCore

struct NotaryCoreTests {
    @Test func decodesAppleHistoryDatesAndStatuses() throws {
        let data = Data(
            """
            {"message":"Successfully received submission history.","history":[
              {"id":"A1B2C3D4-0000-4000-8000-000000000000","name":"App.dmg","status":"In Progress","createdDate":"2026-10-26T09:22:11.123Z"},
              {"id":"A1B2C3D4-0000-4000-8000-000000000001","name":"App.zip","status":"Accepted","createdDate":"2026-10-25T09:22:11Z"}
            ]}
            """.utf8)
        let result = try NotaryJSON.decode(SubmissionHistory.self, from: data)
        #expect(result.history.count == 2)
        #expect(result.history[0].state == .processing)
        #expect(result.history[1].state == .accepted)
        #expect(result.history[0].createdDate > result.history[1].createdDate)
    }

    @Test func rejectsMalformedHistoryInsteadOfInventingData() {
        #expect(throws: (any Error).self) {
            try NotaryJSON.decode(SubmissionHistory.self, from: Data("{}".utf8))
        }
        #expect(throws: (any Error).self) {
            try NotaryJSON.decode(
                SubmissionHistory.self,
                from: Data(
                    """
                    {"history":[{"id":"A1B2C3D4-0000-4000-8000-000000000000","name":"a","status":"Accepted","createdDate":"bad date"}]}
                    """.utf8))
        }
    }

    @Test func unknownStatusesRemainVisibleAndDoNotLookAccepted() {
        let state = SubmissionState("Awaiting Review")
        #expect(state == .unknown("Awaiting Review"))
        #expect(state.label == "Awaiting Review")
        #expect(state.needsAttention)
        #expect(!state.isFinished)
        #expect(SubmissionState("Rejected").needsAttention)
    }

    @Test func filteringSearchAndNewestFirstOrder() {
        let samples = SampleData.submissions()
        #expect(SubmissionFilter.processing.apply(to: samples.reversed(), search: "").count == 2)
        #expect(SubmissionFilter.attention.apply(to: samples, search: "UNIVERSAL").count == 1)
        #expect(SubmissionFilter.all.apply(to: samples, search: "\(samples[2].id)").first?.id == samples[2].id)
        #expect(SubmissionFilter.all.apply(to: samples.reversed(), search: "").first == samples.first)
        #expect(SubmissionFilter.accepted.apply(to: samples, search: "  not present ").isEmpty)
    }

    @Test func clientPassesNamesLiterallyAndIncludesCustomKeychain() async throws {
        let runner = RecordingRunner(data: Data("{\"history\":[]}".utf8))
        let profile = NotaryProfile(name: "profile; $(touch /tmp/no)", keychainPath: "/a path/ci.keychain-db")
        let result = try await NotaryClient(runner: runner).history(profile: profile)
        #expect(result.isEmpty)
        #expect(
            await runner.arguments == [
                "history", "--keychain-profile", "profile; $(touch /tmp/no)", "--keychain", "/a path/ci.keychain-db",
                "--output-format", "json", "--no-progress",
            ])
    }

    @Test func emptyProfileFailsBeforeLaunchingTool() async {
        let runner = RecordingRunner(data: Data())
        await #expect(throws: NotaryError.invalidProfile) {
            try await NotaryClient(runner: runner).history(profile: NotaryProfile(name: "  "))
        }
        #expect(await runner.arguments.isEmpty)
    }

    @Test func sampleLogsDecodeBothNullAndStructuredIssues() throws {
        let samples = SampleData.submissions()
        let accepted = try SampleData.log(for: samples[2])
        #expect(accepted.0.issues == nil)
        let invalid = try SampleData.log(for: samples[4])
        #expect(invalid.0.issues?.count == 1)
        #expect(invalid.0.issues?.first?.severity == "error")
        #expect(invalid.0.jobId == samples[4].id)
    }

    @Test func mismatchedSubmissionResponseFailsClosed() async throws {
        let samples = SampleData.submissions()
        let (_, text) = try SampleData.log(for: samples[2])
        let client = NotaryClient(runner: RecordingRunner(data: Data(text.utf8)))
        await #expect(throws: (any Error).self) {
            try await client.log(id: samples[3].id, profile: NotaryProfile(name: "test"))
        }
    }

    @Test func processRunnerDrainsLargeOutputWithoutPipeDeadlock() async throws {
        let runner = NotaryCommandRunner(
            executable: URL(fileURLWithPath: "/bin/sh"),
            prefix: ["-c", "head -c 200000 /dev/zero; head -c 200000 /dev/zero >&2"], timeout: .seconds(3))
        let data = try await runner.run(arguments: [])
        #expect(data.count == 200_000)
    }

    @Test func processRunnerReportsStderrAndExitStatus() async {
        let runner = NotaryCommandRunner(
            executable: URL(fileURLWithPath: "/bin/sh"), prefix: ["-c", "echo 'Profile not found' >&2; exit 9"])
        await #expect(throws: NotaryError.commandFailed(9, "Profile not found")) {
            try await runner.run(arguments: [])
        }
    }

    @Test func processRunnerTimesOutAndTerminates() async {
        let runner = NotaryCommandRunner(
            executable: URL(fileURLWithPath: "/bin/sleep"), prefix: [], timeout: .milliseconds(100))
        await #expect(throws: NotaryError.timedOut) { try await runner.run(arguments: ["5"]) }
    }

    @Test func processRunnerCancellationIsNotANetworkError() async throws {
        let runner = NotaryCommandRunner(executable: URL(fileURLWithPath: "/bin/sleep"), prefix: [])
        let task = Task { try await runner.run(arguments: ["5"]) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

actor RecordingRunner: CommandRunning {
    let data: Data
    var arguments: [String] = []
    init(data: Data) { self.data = data }
    func run(arguments: [String]) async throws -> Data {
        self.arguments = arguments
        return data
    }
}

actor ControlledService: NotaryServing {
    var failHistory = false
    var historyValues = SampleData.submissions()
    var logRequested = false
    var logContinuation: CheckedContinuation<(NotaryLog, String), any Error>?

    func setFailure(_ value: Bool) { failHistory = value }
    func setHistory(_ history: [Submission]) { historyValues = history }
    func history(profile: NotaryProfile) async throws -> [Submission] {
        if failHistory { throw NotaryError.commandFailed(1, "Offline") }
        return historyValues
    }
    func info(id: UUID, profile: NotaryProfile) async throws -> Submission {
        guard let value = historyValues.first(where: { $0.id == id }) else {
            throw NotaryError.invalidResponse("Missing")
        }
        return value
    }
    func log(id: UUID, profile: NotaryProfile) async throws -> (NotaryLog, String) {
        logRequested = true
        return try await withCheckedThrowingContinuation { logContinuation = $0 }
    }
    func releaseLog(for submission: Submission) throws {
        logContinuation?.resume(returning: try SampleData.log(for: submission))
        logContinuation = nil
    }
}

@MainActor
struct DashboardTests {
    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let name = "NotaryWatch.tests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func refreshFailurePreservesHistoryAndLastSuccessfulRefresh() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ControlledService()
        let model = DashboardModel(client: service, defaults: defaults)
        #expect(await model.connect(NotaryProfile(name: "test")))
        let original = model.submissions
        let lastRefresh = model.lastRefresh
        await service.setFailure(true)
        await model.refresh()
        #expect(model.submissions == original)
        #expect(model.lastRefresh == lastRefresh)
        #expect(model.lastError?.contains("Offline") == true)
        #expect(!model.isBusy)
    }

    @Test func failedProfileSwitchPreservesPreviousConnection() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ControlledService()
        let model = DashboardModel(client: service, defaults: defaults)
        #expect(await model.connect(NotaryProfile(name: "working")))
        await service.setFailure(true)
        #expect(await !model.connect(NotaryProfile(name: "broken")))
        #expect(model.profile?.name == "working")
        #expect(defaults.string(forKey: "profile") == "working")
        #expect(!model.submissions.isEmpty)
    }

    @Test func sampleModeNeverCallsLiveHistoryAndCanExit() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ControlledService()
        await service.setFailure(true)
        let model = DashboardModel(client: service, defaults: defaults, sample: true)
        await model.refresh()
        #expect(model.lastError == nil)
        #expect(model.lastRefresh == nil)
        #expect(!model.isConnected)
        #expect(model.submissions.count == 8)
        await model.leaveSamples()
        #expect(model.submissions.isEmpty)
        #expect(!model.isSample)
    }

    @Test func selectingAnotherSubmissionDiscardsLateLogResponse() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ControlledService()
        let model = DashboardModel(client: service, defaults: defaults)
        #expect(await model.connect(NotaryProfile(name: "test")))
        let first = model.submissions[2]
        model.selectedID = first.id
        let request = Task { await model.loadLog() }
        for _ in 0..<100 {
            if await service.logRequested { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await service.logRequested)
        model.selectedID = model.submissions[3].id
        try await service.releaseLog(for: first)
        await request.value
        #expect(model.log == nil)
        #expect(model.logText == nil)
        #expect(!model.isBusy)
    }

    @Test func checkingOneSubmissionDoesNotRefreshWholeHistoryTimestamp() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ControlledService()
        let model = DashboardModel(client: service, defaults: defaults)
        #expect(await model.connect(NotaryProfile(name: "test")))
        let timestamp = model.lastRefresh
        await model.checkSelected()
        #expect(model.lastRefresh == timestamp)
    }

    @Test func completedSubmissionLeavesProcessingSelectionAfterRefresh() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ControlledService()
        let model = DashboardModel(client: service, defaults: defaults)
        #expect(await model.connect(NotaryProfile(name: "test")))
        model.filter = .processing
        let completed = try #require(model.selected)
        let changed = model.submissions.map { submission in
            submission.id == completed.id
                ? Submission(
                    id: submission.id, name: submission.name, createdDate: submission.createdDate, status: "Accepted")
                : submission
        }
        await service.setHistory(changed)
        await model.refresh()
        #expect(model.selectedID != completed.id)
        #expect(model.selected?.state == .processing)
        #expect(model.visibleSubmissions.count == 1)
    }

    @Test func selectedSubmissionDisappearsCleanlyWhenHistoryIsEmpty() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ControlledService()
        let model = DashboardModel(client: service, defaults: defaults)
        #expect(await model.connect(NotaryProfile(name: "test")))
        await service.setHistory([])
        await model.refresh()
        #expect(model.selectedID == nil)
        #expect(model.submissions.isEmpty)
        #expect(model.lastError == nil)
    }
}
