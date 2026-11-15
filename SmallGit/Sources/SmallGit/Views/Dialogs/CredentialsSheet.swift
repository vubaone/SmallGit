import SwiftUI

/// Asks for the username and password git could not read.
///
/// The host is shown as git reported it, and shown prominently: this dialog
/// appears in response to a network operation, and "which server am I about
/// to type a password into" is the one thing the user must be able to check
/// before answering.
struct CredentialsSheet: View {
    @Bindable var appState: AppState
    let request: CredentialRequest

    @State private var username: String = ""
    @State private var password: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.requiresWorkflowScope ? "Allow workflow updates on \(request.host)" : "Sign in to \(request.host)")
                    .font(.title3.bold())
                Text(request.requiresWorkflowScope
                     ? "GitHub accepted your sign-in, but this push needs permission to update GitHub Actions workflows."
                     : "Sign in to continue \(request.action.lowercased()).")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
            }

            if request.supportsGitHubCLI {
                GitHubSignInSection(appState: appState, request: request)
                Divider()
                Text(request.requiresWorkflowScope ? "Or use an access token with workflow permission" : "Or use a username and access token")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
            }

            Form {
                LabeledContent("Server") {
                    Text(request.url)
                        .scaledFont(11, design: .monospaced)
                        .foregroundStyle(Color.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TextField("Username", text: $username)
                    .accessibilityIdentifier("credentials.username")
                SecureField("Password or access token", text: $password)
                    .accessibilityIdentifier("credentials.password")
            }
            .formStyle(.grouped)
            .disabled(appState.gitHubAuthState.isBusy)

            Text("Saved through Git's configured credential helper, using macOS Keychain when no helper is configured. GitHub requires an access token instead of your account password.")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") {
                    appState.cancelCredentialRequest()
                    dismiss()
                }
                .accessibilityIdentifier("credentials.cancel")
                .keyboardShortcut(.cancelAction)

                Button("Sign In and \(request.action)") {
                    let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
                    let secret = password
                    dismiss()
                    Task {
                        await appState.submitCredentials(
                            for: request,
                            username: user,
                            password: secret
                        )
                    }
                }
                .accessibilityIdentifier("credentials.submit")
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(
                    username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || password.isEmpty
                    || appState.gitHubAuthState.isBusy
                )
            }
        }
        .padding(18)
        .frame(width: 560)
        .background(Color.bgPanel)
        .interactiveDismissDisabled(appState.gitHubAuthState.isBusy)
        .onDisappear { appState.cancelGitHubSignIn() }
        .onAppear {
            username = request.suggestedUsername ?? ""
        }
    }
}

/// All state lives on AppState so the pending CLI process survives redraws
/// and cancellation also works when the sheet disappears.
struct GitHubSignInSection: View {
    @Bindable var appState: AppState
    let request: CredentialRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(request.requiresWorkflowScope ? "Authorize Workflow Access" : "Continue with GitHub CLI") {
                appState.signInWithGitHubCLI(for: request)
            }
            .accessibilityIdentifier("credentials.github")
            .disabled(appState.gitHubAuthState.isBusy)

            Text(request.requiresWorkflowScope
                 ? "Grant the workflow permission to GitHub CLI in your browser. SmallGit will then retry the failed push."
                 : "Use your existing gh account or sign in with a browser. GitHub CLI will manage Git credentials for github.com.")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            switch appState.gitHubAuthState {
            case .idle: EmptyView()
            case .checking:
                progress("Checking GitHub CLI…")
            case .configuring:
                progress("Connecting Git to GitHub CLI…")
            case .waitingForBrowser(let code):
                Text("Enter this one-time code on GitHub:")
                    .scaledFont(11)
                HStack(spacing: 12) {
                    Text(code)
                        .font(.system(.title2, design: .monospaced).bold())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("credentials.githubCode")
                    Button("Copy Code") { appState.copyToPasteboard(code) }
                        .accessibilityIdentifier("credentials.copyGitHubCode")
                    Link("Open GitHub", destination: URL(string: "https://github.com/login/device")!)
                        .accessibilityIdentifier("credentials.openGitHub")
                }
                progress("Waiting for browser approval…")
            case .missingCLI:
                errorMessage(GitHubAuthError.notInstalled.localizedDescription)
                Button("Open In-App Terminal") {
                    appState.prepareGitHubCLIInstallation(for: request)
                }
                .accessibilityIdentifier("credentials.installGitHubCLI")
                .help("Fill in brew install gh. Press Enter in Terminal to run it.")
            case .failed(let message):
                errorMessage(message)
            }
        }
    }

    private func errorMessage(_ message: String) -> some View {
        Text(message)
            .scaledFont(11)
            .foregroundStyle(Color.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("credentials.githubError")
    }

    private func progress(_ message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(message).scaledFont(11)
        }
        .accessibilityIdentifier("credentials.githubProgress")
    }
}
