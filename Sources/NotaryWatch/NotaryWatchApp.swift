import NotaryCore
import SwiftUI

@main
struct NotaryWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = DashboardModel(sample: CommandLine.arguments.contains("--demo"))

    var body: some Scene {
        Window("Notary Watch", id: "dashboard") {
            DashboardView(model: model)
                .tint(Palette.accent)
                .frame(minWidth: 1060, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 780)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh submissions") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(!model.isConnected || model.isBusy)
            }
            CommandGroup(replacing: .help) {
                if let url = URL(
                    string: "https://developer.apple.com/documentation/security/customizing-the-notarization-workflow")
                {
                    Link("Apple Notarization Documentation", destination: url)
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum Palette {
    static let accent = Color(
        nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                NSColor(calibratedRed: 0.48, green: 0.75, blue: 0.61, alpha: 1)
            } else {
                NSColor(calibratedRed: 0.14, green: 0.42, blue: 0.31, alpha: 1)
            }
        })
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
}

extension SubmissionState {
    var color: Color {
        switch self {
        case .accepted: Palette.accent
        case .processing: .orange
        case .invalid, .rejected: .red
        case .unknown: .secondary
        }
    }
    var symbol: String {
        switch self {
        case .accepted: "checkmark.circle.fill"
        case .processing: "clock"
        case .invalid, .rejected: "exclamationmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

struct StateLabel: View {
    let state: SubmissionState
    var body: some View {
        Label(state.label, systemImage: state.symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(state.color)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(state.color.opacity(0.09), in: Capsule())
            .accessibilityLabel("Status: \(state.label)")
    }
}
