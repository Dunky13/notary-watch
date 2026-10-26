import NotaryCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @State private var presentedSheet: DashboardSheet?
    @State private var showRawLog = false
    @FocusState private var searchFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 185, ideal: 205, max: 240)
        } detail: {
            HSplitView {
                history.frame(minWidth: 510, maxWidth: .infinity, maxHeight: .infinity)
                InspectorView(model: model, showRawLog: $showRawLog)
                    .frame(minWidth: 285, idealWidth: 310, maxWidth: 390, maxHeight: .infinity)
            }
        }
        .navigationTitle("Notary Watch")
        .navigationSubtitle(model.isSample ? "Sample workspace" : model.activeProfile?.displayName ?? "Not connected")
        .toolbar {
            ToolbarItemGroup {
                if model.isBusy {
                    ProgressView().controlSize(.small).help(model.activity)
                        .accessibilityLabel(model.activity)
                }
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!model.isConnected || model.isBusy)
                .help("Refresh submissions (⌘R)")
                .accessibilityLabel("Refresh submissions")
                Toggle(isOn: $model.autoRefresh) { Label("Auto-refresh", systemImage: "arrow.triangle.2.circlepath") }
                    .toggleStyle(.button)
                    .disabled(!model.isConnected)
                    .help("Refresh every 30 seconds while this window is active")
                Button {
                    presentedSheet = .connection
                } label: {
                    Label("Connection", systemImage: "key.horizontal")
                }
                .disabled(model.isBusy)
                .accessibilityLabel("Connection")
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .connection: ConnectionView(model: model)
            case .addNew: ConnectionView(model: model, purpose: .addNew)
            case .addExisting: ConnectionView(model: model, purpose: .addExisting)
            case .profiles:
                ProfilesView(model: model) { purpose in
                    presentedSheet = purpose == .addExisting ? .addExisting : .addNew
                }
            }
        }
        .sheet(isPresented: $showRawLog) {
            if let text = model.logText, let submission = model.selected {
                RawLogView(text: text, submission: submission, isSample: model.isSample)
            }
        }
        .background {
            Button("Search submissions") { searchFocused = true }
                .keyboardShortcut("f").hidden()
        }
        .task {
            if model.profile == nil && !model.isSample && model.profileStorageError == nil {
                presentedSheet = .connection
            }
            await model.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
                if model.autoRefresh && scenePhase == .active { await model.refresh() }
            }
        }
        .onChange(of: model.filter) { _, _ in selectVisibleSubmission() }
        .onChange(of: model.search) { _, _ in selectVisibleSubmission() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.accent).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notary Watch").font(.system(size: 15, weight: .semibold))
                    Text("A little release clarity.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 17).padding(.top, 24).padding(.bottom, 30)

            List(selection: $model.filter) {
                Section("SUBMISSIONS") {
                    ForEach(SubmissionFilter.allCases) { filter in
                        HStack(spacing: 9) {
                            Image(systemName: icon(for: filter)).frame(width: 17)
                            Text(filter.rawValue).font(.system(size: 12))
                            Spacer(minLength: 4)
                            Text(model.count(filter), format: .number)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.vertical, 4)
                        .tag(filter)
                    }
                }
            }
            .listStyle(.sidebar)

            VStack(alignment: .leading, spacing: 12) {
                Divider()
                profileMenu
                Text(
                    model.isSample
                        ? "Explore with example submissions."
                        : model.profile?.name ?? "Credentials stay in your Keychain."
                )
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Manage profiles…") { presentedSheet = .profiles }
                    .font(.system(size: 11)).disabled(model.isBusy)
                    .buttonStyle(.link)
            }
            .padding(18)
        }
    }

    private var profileMenu: some View {
        Menu {
            ForEach(model.savedProfiles) { saved in
                Button {
                    Task { await model.activateProfile(saved.id) }
                } label: {
                    if saved.id == model.activeProfileID && !model.isSample {
                        Label(saved.displayName, systemImage: "checkmark")
                    } else {
                        Text(saved.displayName)
                    }
                }
            }
            if !model.savedProfiles.isEmpty { Divider() }
            Button("Set up a new profile…") { presentedSheet = .addNew }
                .disabled(model.profileStorageError != nil)
            Button("Use an existing Keychain profile…") { presentedSheet = .addExisting }
                .disabled(model.profileStorageError != nil)
            Divider()
            Button("Manage profiles…") { presentedSheet = .profiles }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.isSample ? "sparkles" : "person.crop.circle")
                Text(model.isSample ? "Sample workspace" : model.activeProfile?.displayName ?? "Choose a profile")
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }.font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton).disabled(model.isBusy)
        .accessibilityLabel("Switch profile")
        .help("Choose the Apple account or team to monitor")
    }

    private var history: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text("DEVELOPER ID  /  NOTARIZATION")
                    .font(.system(size: 9, weight: .semibold)).tracking(1.7).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline) {
                    Text(model.filter.rawValue).font(.system(size: 27, weight: .semibold)).tracking(-0.7)
                    Spacer()
                    Text(model.visibleSubmissions.count, format: .number)
                        .font(.system(size: 23, weight: .light, design: .rounded)).foregroundStyle(.tertiary)
                }
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search by filename or submission ID", text: $model.search)
                        .textFieldStyle(.plain).focused($searchFocused)
                        .accessibilityLabel("Search submissions")
                    if !model.search.isEmpty {
                        Button {
                            model.search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain).help("Clear search")
                    }
                }
                .font(.system(size: 12)).padding(9)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
            }
            .padding(.horizontal, 26).padding(.top, 26).padding(.bottom, 22)

            if model.isSample {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text("Sample data").fontWeight(.semibold)
                    Text("No Apple account is connected to these results.").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Exit") { Task { await model.leaveSamples() } }.buttonStyle(.link).disabled(model.isBusy)
                }
                .font(.system(size: 10)).padding(.horizontal, 26).padding(.vertical, 10)
                .background(Palette.accent.opacity(0.07))
            }

            if let error = model.lastError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Couldn’t complete the request").fontWeight(.semibold)
                        Text(error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if model.lastRefresh != nil {
                            Text("Showing the last successful history. These results may be out of date.").fontWeight(
                                .medium)
                        }
                        Button("Try again") { Task { await model.refresh() } }
                            .disabled(model.isBusy || !model.isConnected)
                    }
                    Spacer(minLength: 0)
                    Button {
                        model.lastError = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain).help("Dismiss error")
                }
                .font(.system(size: 11)).padding(14).background(.orange.opacity(0.08))
            }

            if model.profile == nil && !model.isSample {
                welcome
            } else if model.visibleSubmissions.isEmpty {
                emptyList
            } else {
                HStack {
                    Text("SUBMISSION").frame(maxWidth: .infinity, alignment: .leading)
                    Text("STATUS").frame(width: 110, alignment: .leading)
                    Text("SUBMITTED").frame(width: 88, alignment: .trailing)
                }
                .font(.system(size: 9, weight: .medium)).tracking(0.8).foregroundStyle(.secondary)
                .padding(.horizontal, 26).padding(.vertical, 12)
                Divider().padding(.horizontal, 20)
                List(model.visibleSubmissions, selection: $model.selectedID) { submission in
                    SubmissionRow(submission: submission)
                        .tag(submission.id)
                        .contextMenu {
                            Button("Copy submission ID") { copyToClipboard(submission.id.uuidString) }
                            Button("Copy filename") { copyToClipboard(submission.name) }
                        }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
            }

            Divider()
            HStack(spacing: 6) {
                if model.isBusy {
                    Text(model.activity)
                } else if model.isSample {
                    Text("Example workspace · Not live data")
                } else if let date = model.lastRefresh {
                    Image(systemName: "checkmark.circle").foregroundStyle(
                        model.lastError == nil ? Palette.accent : .orange)
                    Text("History updated \(date.formatted(date: .omitted, time: .standard))")
                } else {
                    Text("Connect a Keychain profile to get started")
                }
                Spacer()
                if model.isConnected { Text(model.autoRefresh ? "Auto-refresh · 30s" : "Auto-refresh paused") }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .padding(.horizontal, 22).padding(.vertical, 11)
        }
        .background(Palette.canvas)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.seal").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(
                Palette.accent)
            Text("Your releases.\nOne quiet place.")
                .font(.system(size: 31, weight: .medium)).tracking(-0.7)
            Text(
                "See what’s still processing, what’s ready, and what needs a closer look. Connect your saved Apple notarization profile to begin."
            )
            .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Button("Connect to Apple…") { presentedSheet = .connection }.buttonStyle(.borderedProminent)
                    .controlSize(
                        .large)
                Button("Explore sample data") { model.showSamples() }.buttonStyle(.link)
            }
            Text("Requires Xcode and a notarytool Keychain profile.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: 410, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(32)
    }

    private var emptyList: some View {
        ContentUnavailableView {
            Label(
                model.isBusy ? "Loading submissions" : "No submissions here",
                systemImage: model.isBusy ? "arrow.clockwise" : "tray")
        } description: {
            Text(
                model.isBusy
                    ? "Requesting your team’s history from Apple…"
                    : model.search.isEmpty && model.filter == .all
                        ? "Apple returned no recent submissions for this profile. Your team’s older history may not be available."
                        : "Try another filter or search term.")
        } actions: {
            if !model.search.isEmpty || model.filter != .all {
                Button("Show all submissions") {
                    model.search = ""
                    model.filter = .all
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func selectVisibleSubmission() {
        if !model.visibleSubmissions.contains(where: { $0.id == model.selectedID }) {
            model.selectedID = model.visibleSubmissions.first?.id
        }
    }

    private func icon(for filter: SubmissionFilter) -> String {
        switch filter {
        case .all: "tray.full"
        case .processing: "clock"
        case .accepted: "checkmark.circle"
        case .attention: "exclamationmark.circle"
        }
    }
}

struct SubmissionRow: View {
    let submission: Submission
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: submission.name.hasSuffix(".dmg") ? "externaldrive" : "doc.zipper")
                .font(.system(size: 23, weight: .light)).foregroundStyle(.secondary).frame(width: 29)
            VStack(alignment: .leading, spacing: 5) {
                Text(submission.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(submission.id.uuidString.prefix(8).lowercased())
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StateLabel(state: submission.state).frame(width: 110, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                Text(submission.createdDate, format: .dateTime.month(.abbreviated).day())
                Text(submission.createdDate, format: .dateTime.hour().minute()).foregroundStyle(.tertiary)
            }
            .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit().frame(
                width: 72, alignment: .trailing)
        }
        .padding(.vertical, 13)
        .help("\(submission.name)\n\(submission.id.uuidString)\n\(submission.createdDate.formatted())")
        .accessibilityElement(children: .combine)
    }
}

@MainActor
func copyToClipboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}
