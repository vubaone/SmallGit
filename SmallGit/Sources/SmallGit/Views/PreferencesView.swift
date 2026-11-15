import SwiftUI
import AppKit

struct PreferencesView: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GeneralTab(appState: appState)
                    .tabItem { Label("General", systemImage: "gearshape") }

                ColorsTab(appState: appState)
                    .tabItem { Label("Colors", systemImage: "paintpalette") }

                GitTab(appState: appState)
                    .tabItem { Label("Git", systemImage: "terminal") }

                ExternalToolsTab(appState: appState)
                    .tabItem { Label("External Tools", systemImage: "wrench.and.screwdriver") }

                DiagnosticsView(appState: appState)
                    .tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
            }
            .padding(20)

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        // Wider and taller than the 560x480 the settings tabs alone needed:
        // Diagnostics shows a table with eight columns, and at the old size it
        // was a column of ellipses. The other tabs simply get more air.
        .frame(width: 780, height: 580)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var appState: AppState

    var body: some View {
        Form {
            Section {
                // Segmented rather than a menu: three mutually exclusive
                // options, and the one you want is always one click away.
                Picker("Theme", selection: appearanceBinding) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Label(mode.displayName, systemImage: mode.symbolName)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            } footer: {
                Text("System follows the Mac's Light/Dark setting, including its automatic switch. Light and Dark pin SmallGit regardless of the rest of the system.")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
            }

            Section {
                Toggle("Show button labels", isOn: $appState.appConfig.toolbarShowsLabels)
                Toggle("Escape closes secondary views", isOn: $appState.appConfig.escapeClosesSubwindows)
                Toggle("Closing the window quits SmallGit", isOn: $appState.appConfig.quitsOnMainWindowClose)
                Toggle("Single click opens a repository", isOn: $appState.appConfig.singleClickOpensRepo)
            } header: {
                Text("Interface")
            } footer: {
                Text("Escape can close sheets, compare/history windows, and other secondary views. It never closes the main SmallGit window.\n\nThe window's position and size are always remembered, including which display it was on.\n\nWith single click off, clicking a repository only selects it and opening takes a double-click — the way SmartGit works.")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
            }

            Section {
                Picker("Open files / folders in", selection: $appState.appConfig.externalEditor) {
                    ForEach(ExternalEditor.allCases, id: \.self) { editor in
                        Text(editorLabel(editor)).tag(editor)
                    }
                }
                if appState.appConfig.externalEditor == .custom {
                    LabeledContent("App") {
                        HStack(spacing: 6) {
                            TextField("/Applications/MyEditor.app", text: customEditorPathBinding)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                            Button("Browse…") { pickEditor() }
                        }
                    }
                }
            } header: {
                Text("Editor")
            } footer: {
                Text("Used by Open in Editor. System Default opens a file in the app macOS assigns to it, and a folder in the first installed editor from this list (macOS itself would open a folder in Finder). If the chosen editor isn't installed, SmallGit falls back to the macOS default opener.")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
            }

            Section {
                Picker("Default mode", selection: $appState.appConfig.diffMode) {
                    ForEach(DiffMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Toggle("Compact by default (changed regions only; off shows the whole file)", isOn: $appState.appConfig.diffCompactMode)
                Toggle("Ignore whitespace by default", isOn: $appState.appConfig.ignoreWhitespace)
            } header: {
                Text("Diff")
            }

            Section {
                LabeledContent("Base font size") {
                    Stepper(
                        value: $appState.appConfig.monoFontSize,
                        in: AppState.monoFontSizeRange,
                        step: 1
                    ) {
                        Text("\(Int(appState.appConfig.monoFontSize)) pt")
                    }
                }
            } header: {
                Text("Zoom")
            } footer: {
                Text("Controls every panel's text size. Use \u{2318}= / \u{2318}- / \u{2318}0 anywhere in the app to adjust without opening Preferences.")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: appState.appConfig.diffMode)           { _, new in apply { appState.diffVM.diffMode = new } }
        .onChange(of: appState.appConfig.diffCompactMode)    { _, new in apply { appState.diffVM.compactMode = new } }
        .onChange(of: appState.appConfig.ignoreWhitespace)   { _, new in apply { appState.diffVM.ignoreWhitespace = new } }
        .onChange(of: appState.appConfig.monoFontSize)       { _, _ in persist() }
        .onChange(of: appState.appConfig.toolbarShowsLabels) { _, _ in persist() }
        .onChange(of: appState.appConfig.escapeClosesSubwindows) { _, _ in persist() }
        .onChange(of: appState.appConfig.quitsOnMainWindowClose) { _, _ in persist() }
        .onChange(of: appState.appConfig.singleClickOpensRepo) { _, _ in persist() }
        .onChange(of: appState.appConfig.externalEditor)     { _, _ in persist() }
        .onChange(of: appState.appConfig.customEditorPath)   { _, _ in persist() }
    }

    /// Marks editors that aren't on this Mac, so picking one isn't a
    /// silent fall back to the default opener.
    private func editorLabel(_ editor: ExternalEditor) -> String {
        guard !editor.bundleIDs.isEmpty else { return editor.displayName }
        let installed = editor.bundleIDs.contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
        return installed ? editor.displayName : "\(editor.displayName) (not installed)"
    }

    private var customEditorPathBinding: Binding<String> {
        Binding(
            get: { appState.appConfig.customEditorPath ?? "" },
            set: { appState.appConfig.customEditorPath = $0.isEmpty ? nil : $0 }
        )
    }

    private func pickEditor() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Use as editor"
        if panel.runModal() == .OK, let url = panel.url {
            appState.appConfig.customEditorPath = url.path
        }
    }

    private var appearanceBinding: Binding<AppearanceMode> {
        Binding(
            get: { appState.appConfig.appearance },
            set: { appState.setAppearance($0) }
        )
    }

    private func apply(_ side: () -> Void) {
        side()
        persist()
    }

    private func persist() {
        Task { await appState.saveAppConfig() }
    }
}

// MARK: - Colors

/// The compare and conflict colours, editable for the theme in effect.
///
/// Only these: they are the ones people have a real reason to change — a
/// red/green pair that a colour-blind reader cannot tell apart is a diff they
/// cannot read — and each is already funnelled through one palette entry.
private struct ColorsTab: View {
    @Bindable var appState: AppState
    /// Which theme is being edited. The window's own appearance, so what the
    /// wells show is what the app is drawing right now.
    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        Form {
            Section {
                ForEach(DiffColorRole.allCases, id: \.self) { role in
                    row(role)
                }
            } header: {
                Text("Compare & Conflict — \(isDark ? "Dark" : "Light") theme")
            } footer: {
                Text("A colour you pick is remembered for the theme you are in now; the other theme keeps its own until you switch and set it there. Several of these are deliberately semi-transparent so the code stays readable through them — drag the opacity slider in the colour picker to keep that.\n\nAdded line text and Removed line text are also used by the +/- counts and the other added/removed labels around the app.")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
            }

            Section {
                preview
            } header: {
                Text("Preview")
            }

            Section {
                HStack {
                    Text(appState.appConfig.diffColors.isEmpty
                         ? "Every colour is the theme's own."
                         : "Some colours have been changed.")
                        .scaledFont(11)
                        .foregroundStyle(Color.textSecondary)
                    Spacer()
                    Button("Restore Defaults") { appState.resetDiffColors() }
                        .disabled(appState.appConfig.diffColors.isEmpty)
                        .help("Put every compare and conflict colour back, in both Light and Dark")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ role: DiffColorRole) -> some View {
        HStack(spacing: 8) {
            ColorPicker(selection: binding(for: role), supportsOpacity: true) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(role.title)
                    Text(role.caption)
                        .scaledFont(10)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            // Only for a role that has been changed, and only for this theme:
            // a revert arrow next to an untouched colour is a button that
            // claims something was done when it wasn't.
            if isOverridden(role) {
                Button {
                    appState.setDiffColor(role, hex: nil, dark: isDark)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .scaledFont(11)
                }
                .buttonStyle(.borderless)
                .help("Back to the theme's own \(role.title.lowercased())")
            }
        }
    }

    /// A few rows drawn with the real tokens, so the effect of a change is
    /// visible without closing Settings and opening a diff to go and look.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewLine("  func rename(_ branch: String) {", background: nil, foreground: Color.textPrimary)
            previewLine("- try await git.rename(old, new)", background: Color.diffDelBg,
                        foreground: Color.diffDelText, word: Color.diffDelWordBg)
            previewLine("+ try await git.rename(old, next)", background: Color.diffAddBg,
                        foreground: Color.diffAddText, word: Color.diffAddWordBg)
            previewLine("", background: Color.diffEmptyBg, foreground: Color.textPrimary)
            previewLine("<<<<<<< HEAD", background: Color.conflictHighlight, foreground: Color.textPrimary)
            previewLine("  the chunk being resolved", background: Color.conflictHighlightFocused,
                        foreground: Color.textPrimary)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgPanel)
        .overlay(
            RoundedRectangle(cornerRadius: 4).stroke(Color.borderColor, lineWidth: 1)
        )
    }

    private func previewLine(
        _ text: String,
        background: Color?,
        foreground: Color,
        word: Color? = nil
    ) -> some View {
        HStack(spacing: 0) {
            Text(text.isEmpty ? " " : text)
                .scaledFont(11, design: .monospaced)
                .foregroundStyle(foreground)
            if let word {
                Text("next")
                    .scaledFont(11, design: .monospaced)
                    .foregroundStyle(foreground)
                    .padding(.horizontal, 2)
                    .background(word)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private func isOverridden(_ role: DiffColorRole) -> Bool {
        appState.appConfig.diffColors.value(role.rawValue, dark: isDark) != nil
    }

    private func binding(for role: DiffColorRole) -> Binding<Color> {
        Binding(
            get: { DiffPalette.shared.resolvedColor(role, dark: isDark) },
            set: { picked in
                // A colour that will not convert is dropped rather than
                // written as nil, which would silently reset the row.
                guard let hex = NSColor(picked).hexStringRGBA else { return }
                appState.setDiffColor(role, hex: hex, dark: isDark)
            }
        )
    }
}

// MARK: - Git

private struct GitTab: View {
    @Bindable var appState: AppState
    @State private var resolved: String = "(resolving…)"
    @State private var globalName: String = ""
    @State private var globalEmail: String = ""
    @State private var identityLoaded: Bool = false
    @State private var identityError: String?

    var body: some View {
        Form {
            Section {
                TextField("Full name", text: $globalName, prompt: Text("e.g. Jane Doe"))
                    .autocorrectionDisabled()
                TextField("Email", text: $globalEmail, prompt: Text("e.g. jane@example.com"))
                    .autocorrectionDisabled()
                if let identityError {
                    Text(identityError)
                        .scaledFont(11)
                        .foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Save Identity") {
                        Task { await saveIdentity() }
                    }
                    .disabled(!identityLoaded)
                }
            } header: {
                Text("Global Identity")
            } footer: {
                Text("Writes `~/.gitconfig` so every new repo inherits these. Per-repo overrides live in the repository's Settings…")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
            }

            Section {
                TextField("Custom path", text: customPathBinding, prompt: Text("auto-detect"))
                    .autocorrectionDisabled()
                HStack {
                    Spacer()
                    Button("Choose…") { pickGitBinary() }
                }
                LabeledContent("Detected") {
                    Text(resolved)
                        .scaledFont(12, design: .monospaced)
                        .foregroundStyle(Color.textSecondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Git executable")
            }
        }
        .formStyle(.grouped)
        .task {
            await refreshDetected()
            await loadIdentity()
        }
        .onChange(of: appState.appConfig.gitPath) { _, _ in
            Task {
                await appState.saveAppConfig()
                await refreshDetected()
            }
        }
    }

    private var customPathBinding: Binding<String> {
        Binding(
            get: { appState.appConfig.gitPath ?? "" },
            set: { appState.appConfig.gitPath = $0.isEmpty ? nil : $0 }
        )
    }

    private func loadIdentity() async {
        let git = appState.git
        globalName  = (try? await git.configValue(repoPath: nil, key: "user.name",  scope: .global)) ?? ""
        globalEmail = (try? await git.configValue(repoPath: nil, key: "user.email", scope: .global)) ?? ""
        identityLoaded = true
    }

    private func saveIdentity() async {
        let git = appState.git
        do {
            try await write(key: "user.name",  value: globalName)
            try await write(key: "user.email", value: globalEmail)
            identityError = nil
            appState.statusText = "Saved global git identity"
        } catch {
            identityError = "Save failed: \(error.localizedDescription)"
        }

        func write(key: String, value: String) async throws {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                _ = try await git.unsetConfigValue(repoPath: nil, key: key, scope: .global)
            } else {
                _ = try await git.setConfigValue(repoPath: nil, key: key, value: trimmed, scope: .global)
            }
        }
    }

    private func refreshDetected() async {
        do {
            let path = try await ProcessRunner.shared.gitExecutablePath()
            resolved = path
        } catch {
            resolved = "git not found — install Xcode CLT (xcode-select --install)"
        }
    }

    private func pickGitBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/bin")
        panel.prompt = "Use git"
        if panel.runModal() == .OK, let url = panel.url {
            appState.appConfig.gitPath = url.path
        }
    }
}

// MARK: - External Tools

private struct ExternalToolsTab: View {
    @Bindable var appState: AppState

    var body: some View {
        Form {
            Section {
                Picker("Use", selection: $appState.appConfig.externalDiffTool) {
                    ForEach(ExternalDiffTool.allCases, id: \.self) { tool in
                        Text(tool.displayName).tag(tool)
                    }
                }

                if appState.appConfig.externalDiffTool == .custom {
                    LabeledContent("App path") {
                        HStack(spacing: 6) {
                            TextField("/Applications/MyDiff.app", text: customDiffPathBinding)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                            Button("Browse…") { pickDiffTool() }
                        }
                    }
                    LabeledContent("Diff arguments") {
                        TextField("", text: $appState.appConfig.customDiffArgs)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Merge arguments") {
                        TextField("", text: $appState.appConfig.customMergeArgs)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                    }
                }
            } header: {
                Text("Diff Tool")
            } footer: {
                Text(diffToolFooter)
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
            }

            Section {
                LabeledContent("Last import") {
                    Text(appState.appConfig.smartGitConfigPath ?? "never")
                        .scaledFont(12, design: .monospaced)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack {
                    Spacer()
                    Button("Re-sync from SmartGit…") {
                        appState.showSyncFromSmartGitSheet = true
                    }
                }
            } header: {
                Text("SmartGit Import")
            }
        }
        .formStyle(.grouped)
        .onChange(of: appState.appConfig.externalDiffTool)    { _, _ in persist() }
        .onChange(of: appState.appConfig.customDiffToolPath)  { _, _ in persist() }
        .onChange(of: appState.appConfig.customDiffArgs)      { _, _ in persist() }
        .onChange(of: appState.appConfig.customMergeArgs)     { _, _ in persist() }
    }

    private var customDiffPathBinding: Binding<String> {
        Binding(
            get: { appState.appConfig.customDiffToolPath ?? "" },
            set: { appState.appConfig.customDiffToolPath = $0.isEmpty ? nil : $0 }
        )
    }

    private var diffToolFooter: String {
        switch appState.appConfig.externalDiffTool {
        case .builtin:
            return "Uses SmallGit's 2-pane compare for changes and 4-pane resolver for conflicts. Recommended."
        case .custom:
            return "Placeholders: ${leftFile} (HEAD / ours) · ${rightFile} (working tree / theirs) · ${baseFile} · ${mergedFile}. Leave merge arguments empty to use the built-in resolver for conflicts."
        case .beyondCompare, .kaleidoscope, .fileMerge:
            return "Falls back to the built-in view when the tool isn't installed. Conflict resolution falls back to the built-in 4-pane resolver if the chosen tool has no merge mode."
        }
    }

    private func persist() {
        Task { await appState.saveAppConfig() }
    }

    private func pickDiffTool() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Use as diff tool"
        if panel.runModal() == .OK, let url = panel.url {
            appState.appConfig.customDiffToolPath = url.path
        }
    }
}
