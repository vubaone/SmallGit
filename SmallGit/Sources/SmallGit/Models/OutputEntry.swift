import Foundation
import SwiftUI

enum CommandStatus: String, Codable, Sendable {
    case running
    case success
    case failure

    var color: Color {
        switch self {
        case .running: return .yellow
        case .success: return .green
        case .failure: return .red
        }
    }
}

struct OutputLink: Hashable, Sendable, Codable {
    let label: String
    let path: String
}

struct OutputEntry: Identifiable, Hashable, Sendable, Codable {
    let id: UUID
    let timestamp: Date
    var status: CommandStatus
    let action: String
    var detail: String
    /// The git command this entry ran.
    ///
    /// A `var` because most entries don't know it when they start: `runGit`
    /// opens the entry before it has resolved the repository or built the
    /// argument list, and fills this in from the result. Empty means "not
    /// known yet", which the row renders as a running state rather than as a
    /// blank column.
    var command: String
    /// How long the command took. `nil` while it is still running.
    var duration: TimeInterval?
    var link: OutputLink?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        status: CommandStatus = .running,
        action: String,
        detail: String = "",
        command: String,
        duration: TimeInterval? = nil,
        link: OutputLink? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.status = status
        self.action = action
        self.detail = detail
        self.command = command
        self.duration = duration
        self.link = link
    }
}
