import NotaryCore
import SwiftUI

enum DashboardSheet: String, Identifiable {
    case connection, addNew, addExisting, profiles
    var id: Self { self }
}

struct ProfilesView: View {
    @ObservedObject var model: DashboardModel
    let addProfile: (ConnectionPurpose) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var displayName = ""
    @State private var pendingRemoval: SavedNotaryProfile?
    @State private var actionError: String?

    private var selected: SavedNotaryProfile? { model.savedProfiles.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Profiles").font(.system(size: 25, weight: .semibold)).tracking(-0.5)
                    Text("Choose the Apple account or team you want to monitor.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Guided setup…") { addProfile(.addNew) }
                    Button("Use an existing Keychain profile…") { addProfile(.addExisting) }
                } label: {
                    Label("Add profile", systemImage: "plus")
                }
                .fixedSize()
                .disabled(model.isBusy || model.profileStorageError != nil)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isBusy)
            }.padding(24)
            Divider()
            if let error = model.profileStorageError {
                ContentUnavailableView(
                    "Saved profiles could not be loaded", systemImage: "exclamationmark.triangle",
                    description: Text(error))
            } else if model.savedProfiles.isEmpty {
                ContentUnavailableView {
                    Label("Your profiles live here", systemImage: "person.2")
                } description: {
                    Text("Set up a profile for each Apple account or developer team you want to monitor.")
                } actions: {
                    Button("Set up a profile…") { addProfile(.addNew) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                HStack(spacing: 0) {
                    List(model.savedProfiles, selection: $selectedID) { saved in
                        HStack(alignment: .top, spacing: 9) {
                            Image(
                                systemName: saved.id == model.activeProfileID && !model.isSample
                                    ? "checkmark.circle.fill" : "person.crop.circle"
                            )
                            .foregroundStyle(
                                saved.id == model.activeProfileID && !model.isSample ? Palette.accent : .secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(saved.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(saved.credentials.name).font(.system(size: 10)).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }.padding(.vertical, 9).tag(saved.id)
                    }.listStyle(.inset).frame(width: 230)
                    Divider()
                    if let selected {
                        profileDetails(selected)
                    } else {
                        ContentUnavailableView("Select a profile", systemImage: "person.crop.circle")
                    }
                }
            }
            Divider()
            HStack {
                Text("Credentials stay in Keychain. Removing a profile here leaves them intact.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 24).padding(.vertical, 15)
        }
        .frame(width: 760, height: 510).tint(Palette.accent)
        .interactiveDismissDisabled(model.isBusy)
        .onAppear {
            selectedID = model.activeProfileID ?? model.savedProfiles.first?.id
            updateName()
        }
        .onChange(of: selectedID) { _, _ in
            actionError = nil
            updateName()
        }
        .onChange(of: model.savedProfiles) { _, profiles in
            if !profiles.contains(where: { $0.id == selectedID }) {
                selectedID = model.activeProfileID ?? profiles.first?.id
            }
            updateName()
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.displayName ?? "profile")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            if let saved = pendingRemoval {
                Button("Remove profile", role: .destructive) {
                    Task {
                        if await !model.removeProfile(saved.id) { actionError = model.lastError }
                    }
                    pendingRemoval = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(
                "This removes the profile from Notary Watch. Its credentials remain in Keychain and can be added again."
            )
        }
    }

    private func profileDetails(_ saved: SavedNotaryProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(saved.id == model.activeProfileID && !model.isSample ? "ACTIVE PROFILE" : "SAVED PROFILE")
                        .font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Display name").font(.system(size: 12, weight: .medium))
                    HStack {
                        TextField("Personal or Work", text: $displayName).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Profile display name")
                        Button("Save name") {
                            actionError = nil
                            if !model.renameProfile(saved.id, to: displayName) { actionError = model.lastError }
                        }.disabled(
                            displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || displayName == saved.displayName)
                    }
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Keychain profile").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Text(saved.credentials.name).font(.system(size: 12)).textSelection(.enabled)
                    Text(
                        saved.credentials.keychainPath.isEmpty
                            ? "Default data protection Keychain" : saved.credentials.keychainPath
                    )
                    .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Text("Renaming changes the label in this app. The credential reference stays the same.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(
                        saved.id == model.activeProfileID && !model.isSample ? "Check connection" : "Use this profile"
                    ) {
                        Task {
                            actionError = nil
                            if await !model.activateProfile(saved.id) { actionError = model.lastError }
                        }
                    }.buttonStyle(.borderedProminent)
                    Spacer()
                    Button("Remove…", role: .destructive) { pendingRemoval = saved }
                }
                if let error = actionError {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.disabled(model.isBusy)
    }

    private func updateName() { displayName = selected?.displayName ?? "" }
}
