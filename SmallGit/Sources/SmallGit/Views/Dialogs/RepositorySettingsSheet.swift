import AppKit
import SwiftUI

/// Per-repository remote destinations and `user.name` / `user.email`
/// overrides that get written to the
/// repo's `.git/config`. Leaving a field blank deletes the local
/// override so the repo falls back to the global value from
/// Preferences.
///
/// A repository whose folder is gone gets a "Browse…" next to its
/// path, to point the entry at wherever the folder went.
struct RepositorySettingsSheet: View {
    @Bindable var appState: AppState
    @State private var repo: RepositoryEntry

    init(appState: AppState, repo: RepositoryEntry) {
        self.appState = appState
        self._repo = State(initialValue: repo)
    }

    @Environment(\.dismiss) private var dismiss

    @State private var localName: String = ""
    @State private var localEmail: String = ""
    @State private var globalName: String? = nil
    @State private var globalEmail: String? = nil
    @State private var isLoading: Bool = true
    @State private var isSaving: Bool = false
    @State private var isRelocating: Bool = false
    @State private var errorMessage: String?
    @State private var remotes: [GitRemote] = []
    @State private var remoteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape")
                Text("Repository Settings")
                    .font(.title3.bold())
            }

            pathCard

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Remotes")
                            .scaledFont(11, weight: .semibold)
                        remoteFields
                        Divider()
                        Text("User")
                            .scaledFont(11, weight: .semibold)
                        userFields
                            .disabled(!isAvailable)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 300)
            }

            if let errorMessage {
                Text(errorMessage)
                    .scaledFont(11)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("OK")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || isSaving || isRelocating)
            }
        }
        .padding(18)
        .frame(width: 620)
        .background(Color.bgPanel)
        .task { await load() }
    }

    private var availability: RepositoryAvailability {
        appState.availability(for: repo)
    }

    private var isAvailable: Bool { availability.isAvailable }

    private var pathCard: some View {
        locationCard(title: "Local", systemImage: "folder") {
            locationValue(repo.path, label: "Path", copyLabel: "Copy local path")
            if !isAvailable {
                HStack {
                    Text(availability.sidebarBadge)
                        .scaledFont(11)
                        .foregroundStyle(.orange)
                    Spacer(minLength: 0)
                    Button("Browse…") { Task { await browseForFolder() } }
                        .disabled(isRelocating)
                }
            }
        }
    }

    private var userFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            field(
                label: "Full Name",
                text: $localName,
                placeholder: globalName ?? "Not set globally"
            )
            field(
                label: "Git Email",
                text: $localEmail,
                placeholder: globalEmail ?? "Not set globally"
            )
            Text("Leave blank to inherit the global value from Preferences.")
                .scaledFont(10)
                .foregroundStyle(Color.textDisabled)
        }
    }

    @ViewBuilder
    private var remoteFields: some View {
        if !isAvailable {
            Text("Remote information is unavailable until this repository can be opened.")
                .scaledFont(11)
                .foregroundStyle(Color.textDisabled)
        } else if let remoteError {
            Text(remoteError)
                .scaledFont(11)
                .foregroundStyle(.red)
        } else if remotes.isEmpty {
            Text("No remotes configured.")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
        } else {
            ForEach(remotes) { remote in
                locationCard(title: remote.name, systemImage: "network") {
                    if remote.fetchURLs == remote.pushURLs {
                        remoteURLs(remote.fetchURLs, label: "Fetch / Push", remote: remote.name)
                    } else {
                        remoteURLs(remote.fetchURLs, label: "Fetch", remote: remote.name)
                        remoteURLs(remote.pushURLs, label: "Push", remote: remote.name)
                    }
                }
            }
        }
    }

    private func remoteURLs(_ urls: [String], label: String, remote: String) -> some View {
        ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
            locationValue(url, label: label, copyLabel: "Copy \(remote) \(label) URL")
        }
    }

    private func locationCard<Content: View>(
        title: String, systemImage: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .scaledFont(12, weight: .semibold)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgPanelHeader, in: RoundedRectangle(cornerRadius: 6))
    }

    private func locationValue(_ value: String, label: String, copyLabel: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .scaledFont(11, design: .monospaced)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                appState.copyToPasteboard(value)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(copyLabel)
            .accessibilityLabel(copyLabel)
        }
    }

    private func field(label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
                .frame(width: 80, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
        }
    }

    private func browseForFolder() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Locate \(repo.name)"
        panel.directoryURL = nearestExistingAncestor(of: repo.path)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isRelocating = true
        defer { isRelocating = false }
        switch await appState.relocateRepository(repo, to: url.path) {
        case .success(let updated):
            repo = updated
            errorMessage = nil
            isLoading = true
            await load()
        case .failure(let error):
            errorMessage = error.message
        }
    }

    /// Where the panel opens: the deepest folder of the old path that still
    /// exists, which is usually the one the repository was moved out of.
    private func nearestExistingAncestor(of path: String) -> URL? {
        var url = URL(fileURLWithPath: path).deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return url
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private func load() async {
        defer { isLoading = false }
        remotes = []
        remoteError = nil
        let git = appState.git
        globalName  = try? await git.configValue(repoPath: nil, key: "user.name",  scope: .global)
        globalEmail = try? await git.configValue(repoPath: nil, key: "user.email", scope: .global)
        // A folder that isn't there has no local config to read.
        guard isAvailable else {
            localName = ""
            localEmail = ""
            return
        }
        localName  = (try? await git.configValue(repoPath: repo.path, key: "user.name",  scope: .local)) ?? ""
        localEmail = (try? await git.configValue(repoPath: repo.path, key: "user.email", scope: .local)) ?? ""
        do {
            remotes = try await git.remoteDetails(repoPath: repo.path)
        } catch {
            remoteError = "Could not load remotes: \(error.localizedDescription)"
        }
    }

    private func save() async {
        // Nothing was editable, so there is nothing to write.
        guard isAvailable else {
            dismiss()
            return
        }
        isSaving = true
        defer { isSaving = false }
        let git = appState.git
        do {
            try await write(key: "user.name",  trimmed: localName)
            try await write(key: "user.email", trimmed: localEmail)
            appState.statusText = "Saved repo settings for \(repo.name)"
            dismiss()
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }

        func write(key: String, trimmed text: String) async throws {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                // Clear the override so the global value applies.
                _ = try await git.unsetConfigValue(repoPath: repo.path, key: key, scope: .local)
            } else {
                _ = try await git.setConfigValue(repoPath: repo.path, key: key, value: value, scope: .local)
            }
        }
    }
}
