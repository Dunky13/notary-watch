import Foundation

public enum SubmissionState: Equatable, Sendable {
    case accepted, processing, invalid, rejected
    case unknown(String)

    public init(_ value: String) {
        switch value.lowercased() {
        case "accepted": self = .accepted
        case "in progress": self = .processing
        case "invalid": self = .invalid
        case "rejected": self = .rejected
        default: self = .unknown(value)
        }
    }

    public var label: String {
        switch self {
        case .accepted: "Accepted"
        case .processing: "In progress"
        case .invalid: "Invalid"
        case .rejected: "Rejected"
        case .unknown(let value): value
        }
    }

    public var needsAttention: Bool {
        switch self {
        case .invalid, .rejected, .unknown: true
        default: false
        }
    }

    public var isFinished: Bool {
        switch self {
        case .accepted, .invalid, .rejected: true
        default: false
        }
    }
}

public struct Submission: Decodable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let createdDate: Date
    public let status: String

    public var state: SubmissionState { SubmissionState(status) }

    public init(id: UUID, name: String, createdDate: Date, status: String) {
        self.id = id
        self.name = name
        self.createdDate = createdDate
        self.status = status
    }
}

public struct SubmissionHistory: Decodable, Sendable {
    public let history: [Submission]
}

public struct NotaryLog: Decodable, Sendable {
    public struct Issue: Decodable, Identifiable, Sendable {
        public var id: String { "\(severity):\(path ?? ""):\(architecture ?? ""):\(message)" }
        public let severity: String
        public let code: Int?
        public let path: String?
        public let message: String
        public let architecture: String?
        public let docUrl: String?
    }

    public let jobId: UUID
    public let status: String
    public let statusSummary: String
    public let issues: [Issue]?
}

public enum NotaryJSON {
    // Apple emits both whole-second and fractional-second ISO 8601 timestamps.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let seconds = ISO8601DateFormatter()
            if let date = fractional.date(from: value) ?? seconds.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid Apple submission date: \(value)")
        }
        return try decoder.decode(type, from: data)
    }
}

public enum SubmissionFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All submissions"
    case processing = "In progress"
    case accepted = "Accepted"
    case attention = "Needs attention"

    public var id: Self { self }

    public func includes(_ submission: Submission) -> Bool {
        switch self {
        case .all: true
        case .processing: submission.state == .processing
        case .accepted: submission.state == .accepted
        case .attention: submission.state.needsAttention
        }
    }

    public func apply(to submissions: [Submission], search: String) -> [Submission] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return submissions.filter {
            includes($0)
                && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                    || $0.id.uuidString.localizedCaseInsensitiveContains(query))
        }.sorted { $0.createdDate > $1.createdDate }
    }
}
