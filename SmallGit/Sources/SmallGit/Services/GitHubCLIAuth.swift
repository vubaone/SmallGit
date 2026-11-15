import Foundation

enum GitHubAuthState: Equatable, Sendable {
    case idle
    case checking
    case waitingForBrowser(code: String)
    case configuring
    case missingCLI
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .waitingForBrowser, .configuring: return true
        case .idle, .missingCLI, .failed: return false
        }
    }
}

protocol GitHubAuthenticating: Sendable {
    func connect(requiresWorkflowScope: Bool, progress: @escaping @Sendable (GitHubAuthState) async -> Void) async throws
}

enum GitHubAuthError: Error, LocalizedError, Equatable {
    case notInstalled, loginFailed, workflowAuthorizationFailed, setupFailed, timedOut

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "GitHub CLI was not found. Install it with brew install gh, then try again."
        case .loginFailed:
            return "GitHub sign-in did not finish. Try again, or check gh auth status in Terminal. If you use GH_TOKEN, check that it is still valid."
        case .workflowAuthorizationFailed:
            return "Workflow permission was not granted. Try again, or run gh auth refresh --hostname github.com --scopes workflow in Terminal. If GH_TOKEN is set, update its permissions or remove it before refreshing gh credentials."
        case .setupFailed:
            return "Signed in, but Git could not be configured. Check gh auth setup-git --hostname github.com in Terminal, then try again."
        case .timedOut:
            return "GitHub sign-in timed out. Try again to get a new code."
        }
    }
}

/// Delegates token storage and Git credentials to gh. SmallGit never asks
/// for `gh auth token`, reads its config, or copies a token to another store.
struct GitHubCLIAuth: GitHubAuthenticating {
    let runner: ProcessRunner
    private let executable: String?
    private let loginTimeout: Duration

    init(runner: ProcessRunner = .shared, executable: String? = nil,
         loginTimeout: Duration = .seconds(600)) {
        self.runner = runner
        self.executable = executable
        self.loginTimeout = loginTimeout
    }

    private static let environment = [
        "GH_PROMPT_DISABLED": "1", "GH_DEBUG": "", "GH_FORCE_TTY": "",
        "NO_COLOR": "1", "CLICOLOR": "0", "GH_PAGER": "cat",
        "GH_NO_UPDATE_NOTIFIER": "1", "GH_NO_EXTENSION_UPDATE_NOTIFIER": "1",
        // Noninteractive gh prints the device URL. The sheet offers a link
        // the user opens explicitly, rather than stealing browser focus.
        "GH_BROWSER": "/usr/bin/false", "BROWSER": "/usr/bin/false"
    ]

    func connect(requiresWorkflowScope: Bool = false,
                 progress: @escaping @Sendable (GitHubAuthState) async -> Void) async throws {
        try Task.checkCancellation()
        guard let path = await resolvedExecutable() else { throw GitHubAuthError.notInstalled }
        await progress(.checking)
        let status = try await runner.runExecutable(path,
            args: ["auth", "status", "--active", "--hostname", "github.com"], env: Self.environment)
        try Task.checkCancellation()
        if !status.succeeded || requiresWorkflowScope {
            let refreshing = status.succeeded
            var args = refreshing
                ? ["auth", "refresh", "--hostname", "github.com", "--scopes", "workflow", "--clipboard=false"]
                : ["auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web", "--clipboard=false"]
            if !refreshing && requiresWorkflowScope { args += ["--scopes", "workflow"] }
            let authorizationArgs = args
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await authorize(path: path, args: authorizationArgs,
                                        requiresWorkflowScope: requiresWorkflowScope, progress: progress)
                }
                group.addTask {
                    try await Task.sleep(for: loginTimeout)
                    throw GitHubAuthError.timedOut
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        }
        try Task.checkCancellation()
        await progress(.configuring)
        let setup = try await runner.runExecutable(path,
            args: ["auth", "setup-git", "--hostname", "github.com"], env: Self.environment)
        try Task.checkCancellation()
        guard setup.succeeded else { throw GitHubAuthError.setupFailed }
    }

    private func resolvedExecutable() async -> String? {
        if let executable {
            return FileManager.default.isExecutableFile(atPath: executable) ? executable : nil
        }
        return await runner.executablePath(named: "gh")
    }

    private func authorize(path: String, args: [String], requiresWorkflowScope: Bool,
                           progress: @escaping @Sendable (GitHubAuthState) async -> Void) async throws {
        let events = await runner.stream(executable: path, args: args, cwd: nil, env: Self.environment)
        var exitCode: Int32?
        for try await event in events {
            try Task.checkCancellation()
            switch event {
            case .line(let line):
                if let code = Self.deviceCode(in: line) { await progress(.waitingForBrowser(code: code)) }
            case .exit(let code): exitCode = code
            }
        }
        try Task.checkCancellation()
        guard exitCode == 0 else {
            throw requiresWorkflowScope ? GitHubAuthError.workflowAuthorizationFailed : .loginFailed
        }
    }

    /// Parse only the short device code, never display or persist raw CLI
    /// output. An unknown output format can still use the manual token form.
    static func deviceCode(in line: String) -> String? {
        guard line.contains("one-time code"),
              let range = line.range(of: #"\b[A-Z0-9]{4}-[A-Z0-9]{4}\b"#, options: .regularExpression)
        else { return nil }
        return String(line[range])
    }
}
