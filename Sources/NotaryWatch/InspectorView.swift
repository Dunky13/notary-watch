import NotaryCore
import SwiftUI

struct InspectorView: View {
    @ObservedObject var model: DashboardModel
    @Binding var showRawLog: Bool

    var body: some View {
        ScrollView {
            if let submission = model.selected {
                VStack(alignment: .leading, spacing: 24) {
                    Text("SUBMISSION DETAILS").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(
                        .secondary)
                    VStack(alignment: .leading, spacing: 15) {
                        Image(systemName: submission.name.hasSuffix(".dmg") ? "externaldrive" : "doc.zipper")
                            .font(.system(size: 38, weight: .ultraLight)).foregroundStyle(.secondary)
                        Text(submission.name).font(.system(size: 18, weight: .semibold)).tracking(-0.3)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        StateLabel(state: submission.state)
                        Text(explanation(for: submission.state))
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 18) {
                        field("Submitted") {
                            Text(
                                submission.createdDate,
                                format: .dateTime.day().month(.wide).year().hour().minute().second())
                            Text(TimeZone.current.identifier).foregroundStyle(.tertiary).font(.system(size: 10))
                        }
                        field("Submission ID") {
                            HStack(alignment: .top, spacing: 5) {
                                Text(submission.id.uuidString.lowercased()).font(.system(size: 10, design: .monospaced))
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Button {
                                    copyToClipboard(submission.id.uuidString)
                                } label: {
                                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                                }.buttonStyle(.plain).help("Copy submission ID")
                            }
                        }
                        field("Source") {
                            Label(
                                model.isSample ? "Sample data" : "Apple notary service",
                                systemImage: model.isSample ? "sparkles" : "checkmark.shield")
                        }
                    }
                    HStack {
                        Button {
                            Task { await model.checkSelected() }
                        } label: {
                            Label("Check status", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isBusy || model.isSample)
                        .accessibilityLabel("Check status")
                        Button {
                            Task { await model.loadLog() }
                        } label: {
                            Label("Fetch log", systemImage: "text.document")
                        }
                        .disabled(model.isBusy || !submission.state.isFinished)
                        .accessibilityLabel("Fetch log")
                    }.controlSize(.small)

                    if submission.state == .processing {
                        Label("Logs become available after processing completes.", systemImage: "info.circle")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }

                    if let log = model.log {
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("NOTARIZATION LOG").font(.system(size: 9, weight: .semibold)).tracking(1)
                                Spacer()
                                Button("JSON") { showRawLog = true }.buttonStyle(.link).font(.system(size: 10))
                                    .accessibilityLabel("View raw JSON log")
                            }.foregroundStyle(.secondary)
                            Text(log.statusSummary).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                            if let issues = log.issues, !issues.isEmpty {
                                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                                    VStack(alignment: .leading, spacing: 7) {
                                        Label(
                                            issue.severity.capitalized,
                                            systemImage: issue.severity.lowercased() == "error"
                                                ? "xmark.circle.fill" : "exclamationmark.triangle.fill"
                                        )
                                        .foregroundStyle(issue.severity.lowercased() == "error" ? .red : .orange)
                                        .font(.system(size: 11, weight: .semibold))
                                        Text(issue.message).font(.system(size: 12)).textSelection(.enabled)
                                        if let path = issue.path {
                                            Text(path).font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(.secondary).textSelection(.enabled)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        if let architecture = issue.architecture {
                                            Text(architecture).font(.system(size: 10)).foregroundStyle(.tertiary)
                                        }
                                    }
                                    .padding(.vertical, 10)
                                    Divider()
                                }
                            } else {
                                Label("No issues reported in this log.", systemImage: "checkmark.circle")
                                    .foregroundStyle(Palette.accent).font(.system(size: 11))
                            }
                        }
                    }
                    Spacer(minLength: 20)
                }
                .padding(24)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sidebar.right").font(.system(size: 28, weight: .ultraLight))
                    Text("The details live here.").font(.system(size: 13, weight: .medium))
                    Text("Select a submission to see its status and diagnostic log.")
                        .font(.system(size: 12)).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary).padding(35).padding(.top, 160)
            }
        }
        .background(Palette.panel.opacity(0.6))
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            content().font(.system(size: 12))
        }
    }

    private func explanation(for state: SubmissionState) -> String {
        switch state {
        case .accepted: "Apple accepted this submission. Check its log for warnings before distributing."
        case .processing: "Your archive is with Apple. The result will appear here when processing finishes."
        case .invalid, .rejected: "Apple could not accept this archive. Fetch the log to see what needs fixing."
        case .unknown: "Apple returned an unrecognized status. Check the submission again for the latest result."
        }
    }
}

struct RawLogView: View {
    let text: String
    let submission: Submission
    let isSample: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isSample ? "Sample notarization log" : "Apple notarization log").font(.title3.bold())
                    Text(submission.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy JSON") { copyToClipboard(text) }
                Button("Save…") { save() }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(20)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }.background(Palette.canvas)
            if let exportError { Text(exportError).foregroundStyle(.red).font(.caption).padding(12) }
        }
        .frame(width: 780, height: 570)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            "\(isSample ? "sample-" : "")notarization-\(submission.id.uuidString.lowercased()).json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch {
                exportError = error.localizedDescription
            }
        }
    }
}
