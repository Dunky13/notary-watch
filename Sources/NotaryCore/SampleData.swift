import Foundation

public enum SampleData {
    public static func submissions(now: Date = .now) -> [Submission] {
        let entries: [(String, String, TimeInterval)] = [
            ("Northstar-2.4.0-arm64.dmg", "In Progress", 240),
            ("Northstar-2.4.0-universal.zip", "In Progress", 580),
            ("Northstar-2.3.2-arm64.dmg", "Accepted", 3_600),
            ("Northstar-2.3.2-x64.dmg", "Accepted", 3_720),
            ("Northstar-2.3.1-universal.zip", "Invalid", 86_400),
            ("Northstar-2.3.1-arm64.dmg", "Accepted", 90_000),
            ("Northstar-2.3.0-arm64.dmg", "Accepted", 172_800),
            ("Northstar-2.2.0-universal.zip", "Accepted", 259_200),
        ]
        return entries.enumerated().map { index, entry in
            Submission(
                id: UUID(
                    uuid: (UInt8(0xA1 + index), 0xB2, 0xC3, 0xD4, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, UInt8(index))),
                name: entry.0, createdDate: now.addingTimeInterval(-entry.2), status: entry.1)
        }
    }

    public static func log(for submission: Submission) throws -> (NotaryLog, String) {
        let issues: String
        if submission.state == .accepted {
            issues = "null"
        } else {
            issues = """
                [{
                    "severity": "error",
                    "code": 4000,
                    "path": "Northstar.app/Contents/Frameworks/Updater.framework/Updater",
                    "message": "The binary is not signed with a valid Developer ID certificate.",
                    "architecture": "arm64"
                }]
                """
        }
        let text = """
            {
              "logFormatVersion": 1,
              "jobId": "\(submission.id.uuidString)",
              "status": "\(submission.status)",
              "statusSummary": "\(submission.state == .accepted ? "Ready for distribution" : "Archive contains critical validation errors")",
              "issues": \(issues)
            }
            """
        return (try NotaryJSON.decode(NotaryLog.self, from: Data(text.utf8)), text)
    }
}
