import Darwin
import Foundation

public struct NotaryProfile: Codable, Equatable, Sendable {
    public let name: String
    public let keychainPath: String

    public init(name: String, keychainPath: String = "") {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.keychainPath = keychainPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var arguments: [String] {
        var result = ["--keychain-profile", name]
        if !keychainPath.isEmpty { result += ["--keychain", keychainPath] }
        return result
    }
}

public enum NotaryError: LocalizedError, Equatable {
    case commandFailed(Int32, String)
    case timedOut
    case outputTooLarge
    case invalidProfile
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let code, let message):
            "notarytool exited with code \(code). \(message)"
        case .timedOut:
            "Apple did not respond within 60 seconds. Check your connection or Keychain access, then try again."
        case .outputTooLarge:
            "The response exceeded the 20 MB limit. Fetch this submission directly with notarytool."
        case .invalidProfile:
            "Enter the name of a saved notarytool Keychain profile."
        case .invalidResponse(let message):
            "Apple returned an unexpected response. \(message)"
        }
    }
}

public protocol CommandRunning: Sendable {
    func run(arguments: [String]) async throws -> Data
}

/// Uses files for stdout/stderr so neither pipe can fill and deadlock the process.
/// No shell is involved. Names and paths are always literal arguments.
public actor NotaryCommandRunner: CommandRunning {
    private let executable: URL
    private let prefix: [String]
    private let timeout: Duration

    public init(
        executable: URL = URL(fileURLWithPath: "/usr/bin/xcrun"), prefix: [String] = ["notarytool"],
        timeout: Duration = .seconds(60)
    ) {
        self.executable = executable
        self.prefix = prefix
        self.timeout = timeout
    }

    public func run(arguments: [String]) async throws -> Data {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("output")
        let errorURL = directory.appendingPathComponent("error")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? errors.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = prefix + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        let deadline = ContinuousClock.now.advanced(by: timeout)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                if ContinuousClock.now >= deadline { throw NotaryError.timedOut }
                if try fileSize(outputURL) > 20_000_000 || fileSize(errorURL) > 20_000_000 {
                    throw NotaryError.outputTooLarge
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            if process.isRunning {
                process.terminate()
                // Give xcrun/notarytool a bounded opportunity to exit, including on cancellation.
                for _ in 0..<10 where process.isRunning {
                    try? await Task<Never, Never>.sleep(for: .milliseconds(50))
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            throw error
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        guard try fileSize(outputURL) <= 20_000_000, try fileSize(errorURL) <= 20_000_000 else {
            throw NotaryError.outputTooLarge
        }
        let data = try Data(contentsOf: outputURL)
        guard process.terminationStatus == 0 else {
            let diagnostic = try String(contentsOf: errorURL, encoding: .utf8)
            let message = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NotaryError.commandFailed(
                process.terminationStatus,
                message.isEmpty ? String(decoding: data.prefix(4096), as: UTF8.self) : String(message.prefix(4096)))
        }
        return data
    }

    private func fileSize(_ url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }
}

public protocol NotaryServing: Sendable {
    func history(profile: NotaryProfile) async throws -> [Submission]
    func info(id: UUID, profile: NotaryProfile) async throws -> Submission
    func log(id: UUID, profile: NotaryProfile) async throws -> (NotaryLog, String)
}

public struct NotaryClient: NotaryServing {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = NotaryCommandRunner()) { self.runner = runner }

    public func history(profile: NotaryProfile) async throws -> [Submission] {
        let data = try await run("history", profile: profile)
        return try decode(SubmissionHistory.self, data: data).history.sorted { $0.createdDate > $1.createdDate }
    }

    public func info(id: UUID, profile: NotaryProfile) async throws -> Submission {
        let data = try await run("info", id: id, profile: profile)
        let submission = try decode(Submission.self, data: data)
        guard submission.id == id else {
            throw NotaryError.invalidResponse("Submission ID does not match the request.")
        }
        return submission
    }

    public func log(id: UUID, profile: NotaryProfile) async throws -> (NotaryLog, String) {
        let data = try await run("log", id: id, profile: profile)
        let log = try decode(NotaryLog.self, data: data)
        guard log.jobId == id else { throw NotaryError.invalidResponse("Log ID does not match the request.") }
        return (log, String(decoding: data, as: UTF8.self))
    }

    private func run(_ command: String, id: UUID? = nil, profile: NotaryProfile) async throws -> Data {
        guard !profile.name.isEmpty else { throw NotaryError.invalidProfile }
        var arguments = [command]
        if let id { arguments.append(id.uuidString) }
        arguments += profile.arguments + ["--output-format", "json", "--no-progress"]
        return try await runner.run(arguments: arguments)
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        do { return try NotaryJSON.decode(type, from: data) } catch {
            throw NotaryError.invalidResponse(error.localizedDescription)
        }
    }
}
