import SwiftUI

struct SyncFromSmartGitView: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var scanning: Bool = true
    @State private var detected: SmartGitConfig?
    @State private var includeMissing: Bool = false
    @State private var importing: Bool = false

    private let importer = SmartGitImporter()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync from SmartGit").font(.title3.bold())

            if scanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning ~/Library/Preferences/SmartGit…")
                        .foregroundStyle(Color.textSecondary)
                }
            } else if let detected {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Found SmartGit \(detected.version)")
                        .scaledFont(12, weight: .semibold)
                    Text(detected.configPath.path)
                        .scaledFont(12, design: .monospaced)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Divider()

                summaryRow(
                    icon: "checkmark.circle.fill",
                    label: "Repositories",
                    detail: "\(detected.validRepositories.count) valid"
                        + (detected.missingRepositories.isEmpty
                           ? ""
                           : " · \(detected.missingRepositories.count) missing"),
                    color: .green
                )
                summaryRow(
                    icon: "folder.fill",
                    label: "Groups",
                    detail: "\(detected.groups.count)",
                    color: .blue
                )
                summaryRow(
                    icon: "person.badge.key.fill",
                    label: "Credentials",
                    detail: "\(detected.credentials.count) URLs (passwords skipped)",
                    color: .orange
                )
                summaryRow(
                    icon: "keyboard.fill",
                    label: "Keyboard Shortcuts",
                    detail: "\(detected.shortcuts.count)",
                    color: .purple
                )

                if !detected.missingRepositories.isEmpty {
                    Toggle("Also import \(detected.missingRepositories.count) missing paths", isOn: $includeMissing)
                        .toggleStyle(.checkbox)
                        .scaledFont(11)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "questionmark.folder")
                        .scaledFont(28)
                        .foregroundStyle(Color.textDisabled)
                    Text("No SmartGit installation found")
                        .foregroundStyle(Color.textSecondary)
                    Text("Looked under ~/Library/Preferences/SmartGit/")
                        .scaledFont(10)
                        .foregroundStyle(Color.textDisabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(importing ? "Importing…" : "Import") {
                    guard let detected else { return }
                    importing = true
                    Task {
                        await runImport(detected)
                        importing = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(detected == nil || importing)
            }
        }
        .padding(18)
        .frame(minWidth: 480, minHeight: 360)
        .background(Color.bgPanel)
        .task {
            scanning = true
            self.detected = await importer.detect()
            scanning = false
        }
    }

    private func runImport(_ config: SmartGitConfig) async {
        let updated = await importer.materialize(
            config,
            into: appState.repositoriesConfig,
            includeMissing: includeMissing
        )
        appState.repositoriesConfig = updated
        var newAppConfig = appState.appConfig
        newAppConfig.syncedFromSmartGit = true
        newAppConfig.smartGitConfigPath = config.configPath.path
        appState.appConfig = newAppConfig
        try? await appState.config.saveRepositories(updated)
        try? await appState.config.saveAppConfig(newAppConfig)
        if appState.activeRepo == nil, let first = appState.allRepositories.first {
            await appState.selectRepo(first)
        }
    }

    private func summaryRow(icon: String, label: String, detail: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(label)
            Spacer()
            Text(detail)
                .foregroundStyle(Color.textSecondary)
        }
        .scaledFont(12)
    }
}
