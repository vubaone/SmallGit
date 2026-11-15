import Foundation

/// One shell startup per app session. Besides avoiding repeated startup cost,
/// this matches Terminal's semantics: edits to shell profiles affect newly
/// opened sessions, not commands already running in an existing one.
actor UserShellEnvironment {
    static let shared = UserShellEnvironment()

    private var loadTask: Task<[String: String], Never>?

    func load() async -> [String: String] {
        if let loadTask { return await loadTask.value }
        let task = Task { await ProcessRunner.captureUserShellEnvironment() }
        loadTask = task
        return await task.value
    }
}
