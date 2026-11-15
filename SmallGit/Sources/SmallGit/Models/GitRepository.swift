import Foundation

struct RepositoryEntry: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var path: String
    var name: String
    var currentBranch: String?
    var isFavorite: Bool
    /// Which refs this repo's journal graphs — the Branches panel's
    /// checkboxes. Optional so config files written before ref selection
    /// existed still decode; nil means the default, HEAD alone.
    var logSelection: JournalRefSelection?

    init(
        id: UUID = UUID(),
        path: String,
        name: String? = nil,
        currentBranch: String? = nil,
        isFavorite: Bool = false,
        logSelection: JournalRefSelection? = nil
    ) {
        self.id = id
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.currentBranch = currentBranch
        self.isFavorite = isFavorite
        self.logSelection = logSelection
    }
}

enum RepositoryAvailability: Hashable, Sendable {
    case available
    case missingPath
    case notRepository

    var isAvailable: Bool {
        self == .available
    }

    var sidebarBadge: String {
        switch self {
        case .available:      return ""
        case .missingPath:    return "Not Found"
        case .notRepository:  return "Not a Repo"
        }
    }

    var emptyStateIcon: String {
        switch self {
        case .available:      return "folder"
        case .missingPath:    return "questionmark.folder"
        case .notRepository:  return "exclamationmark.triangle"
        }
    }

    var emptyStateTitle: String {
        switch self {
        case .available:      return ""
        case .missingPath:    return "Repository not found"
        case .notRepository:  return "Not a Git repository"
        }
    }

    func emptyStateMessage(path: String) -> String {
        switch self {
        case .available:
            return ""
        case .missingPath:
            return "The saved folder no longer exists at \(path). Restore it or remove this repository from the sidebar."
        case .notRepository:
            return "The saved folder exists, but Git no longer recognizes it as a repository root."
        }
    }
}

struct RepositoryGroup: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var expanded: Bool
    var repositories: [RepositoryEntry]

    init(
        id: UUID = UUID(),
        name: String,
        expanded: Bool = true,
        repositories: [RepositoryEntry] = []
    ) {
        self.id = id
        self.name = name
        self.expanded = expanded
        self.repositories = repositories
    }
}

struct RepositoriesConfig: Codable, Sendable {
    var groups: [RepositoryGroup]
    var ungrouped: [RepositoryEntry]
    /// Disclosure state of the "Other" (ungrouped) section. Named
    /// groups carry their own `expanded` flag; this is the
    /// equivalent for the catch-all bucket so all sections can
    /// collapse uniformly the way SmartGit does it.
    var ungroupedExpanded: Bool

    init(
        groups: [RepositoryGroup] = [],
        ungrouped: [RepositoryEntry] = [],
        ungroupedExpanded: Bool = true
    ) {
        self.groups = groups
        self.ungrouped = ungrouped
        self.ungroupedExpanded = ungroupedExpanded
    }

    // Tolerant decode so existing config files (written before the
    // `ungroupedExpanded` flag existed) still load, defaulting to
    // open just like a freshly-created group.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.groups            = try c.decodeIfPresent([RepositoryGroup].self, forKey: .groups)            ?? []
        self.ungrouped         = try c.decodeIfPresent([RepositoryEntry].self, forKey: .ungrouped)         ?? []
        self.ungroupedExpanded = try c.decodeIfPresent(Bool.self,              forKey: .ungroupedExpanded) ?? true
    }
}
