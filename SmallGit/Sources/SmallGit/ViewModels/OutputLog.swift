import Foundation
import Observation

/// Observable command journal feeding the bottom-right Output panel.
///
/// AppState writes to this for every git invocation: an entry is added in
/// `.running` state, then mutated to `.success` / `.failure` once the call
/// completes (with stdout/stderr concatenated as `detail`).
@MainActor
@Observable
final class OutputLog {

    private(set) var entries: [OutputEntry] = []
    /// Cap on retained entries — older entries are dropped FIFO.
    var maxEntries: Int = 500

    func begin(action: String, command: String) -> UUID {
        let entry = OutputEntry(status: .running, action: action, command: command)
        append(entry)
        return entry.id
    }

    func finish(id: UUID, result: GitCommandResult) {
        update(id: id) {
            $0.status = result.succeeded ? .success : .failure
            $0.detail = result.combinedOutput
            $0.duration = result.duration
            // The command the entry was opened with is a placeholder for
            // anything routed through `runGit`, which cannot know the argument
            // list until the operation has run. Without this the row kept
            // showing that placeholder after finishing, so the panel never
            // reported what it had actually executed.
            if !result.command.isEmpty {
                $0.command = result.command
            }
        }
    }

    /// For work that finishes without a `GitCommandResult` — a guard that
    /// fails before anything runs, or a multi-step operation reporting its own
    /// summary.
    func finish(id: UUID, status: CommandStatus, detail: String, link: OutputLink? = nil) {
        update(id: id) {
            $0.status = status
            $0.detail = detail
            $0.link = link
        }
    }

    func clear() {
        entries.removeAll(keepingCapacity: true)
    }

    // MARK: - Internal

    private func append(_ entry: OutputEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    private func update(id: UUID, _ mutate: (inout OutputEntry) -> Void) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries[idx]
        mutate(&entry)
        entries[idx] = entry
    }
}
