import AppKit
import NotaryCore

@MainActor
enum SetupTerminal {
    static func open(details: SetupDetails) async throws {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw SetupError.terminalUnavailable
        }
        let script = try details.terminalScript()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NotaryWatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("Save Notary Watch credentials.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: configuration)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
