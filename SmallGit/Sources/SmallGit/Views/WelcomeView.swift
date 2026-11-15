import SwiftUI

struct WelcomeView: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .scaledFont(48, weight: .light)
                    .foregroundStyle(Color.accentBlue)
                Text("Welcome to SmallGit")
                    .font(.title2.bold())
                Text("Small but mighty. Free but better.")
                    .scaledFont(12)
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(.top, 24)

            VStack(spacing: 10) {
                WelcomeOption(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Sync from SmartGit",
                    subtitle: "Import repositories, groups and settings from your existing SmartGit install."
                ) {
                    finish(then: { appState.showSyncFromSmartGitSheet = true })
                }

                WelcomeOption(
                    icon: "folder",
                    title: "Open a Repository",
                    subtitle: "Browse to an existing git repository on disk."
                ) {
                    finish(then: { appState.presentOpenRepository() })
                }

                WelcomeOption(
                    icon: "sparkles",
                    title: "Start Fresh",
                    subtitle: "Begin with a clean configuration. You can add repositories later."
                ) {
                    finish()
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(minWidth: 520, minHeight: 460)
        .background(Color.bgPanel)
    }

    /// Dismisses the welcome sheet, persists app config so the support
    /// directory exists (`isFirstLaunch` won't return on next launch),
    /// then runs an optional follow-up action on the next runloop tick so
    /// SwiftUI can finish the sheet transition before presenting a new one.
    private func finish(then followUp: (() -> Void)? = nil) {
        appState.isFirstLaunch = false
        Task { try? await appState.config.saveAppConfig(appState.appConfig) }
        dismiss()
        if let followUp {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                followUp()
            }
        }
    }
}

private struct WelcomeOption: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .scaledFont(24)
                    .frame(width: 36, height: 36)
                    .foregroundStyle(Color.accentBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .scaledFont(13, weight: .semibold)
                    Text(subtitle)
                        .scaledFont(11)
                        .foregroundStyle(Color.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .scaledFont(11)
                    .foregroundStyle(Color.textDisabled)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.bgPanelHeader)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.borderColor, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
