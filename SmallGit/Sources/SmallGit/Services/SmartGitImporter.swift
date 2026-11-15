import Foundation
import Yams

struct SmartGitRepository: Sendable, Hashable {
    let path: String
    let name: String
    let group: String?
    /// `true` if the path exists on disk and contains a `.git/` entry.
    let valid: Bool
}

struct SmartGitConfig: Sendable {
    let version: String
    let configPath: URL
    var repositories: [SmartGitRepository]
    var credentials: [(url: String, username: String)]
    var shortcuts: [String: String]

    var validRepositories: [SmartGitRepository] { repositories.filter(\.valid) }
    var missingRepositories: [SmartGitRepository] { repositories.filter { !$0.valid } }
    var groups: [String] {
        let names = repositories.compactMap(\.group)
        return Array(Set(names)).sorted()
    }
}

/// Scans macOS for a SmartGit installation and imports its repository list.
/// Only reads — never modifies SmartGit's own state.
actor SmartGitImporter {

    private let fm = FileManager.default

    /// Returns the newest SmartGit version directory under
    /// `~/Library/Preferences/SmartGit/<version>/`, or `nil` if none.
    func detect() async -> SmartGitConfig? {
        let prefsDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/SmartGit", isDirectory: true)

        guard let contents = try? fm.contentsOfDirectory(
            at: prefsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let versionDirs = contents
            .filter {
                let name = $0.lastPathComponent
                return name.range(of: #"^\d+\.\d+$"#, options: .regularExpression) != nil
            }
            .sorted {
                $0.lastPathComponent.compare(
                    $1.lastPathComponent,
                    options: .numeric
                ) == .orderedDescending
            }

        guard let newest = versionDirs.first else { return nil }
        return await parse(versionDirectory: newest)
    }

    /// Parses a specific SmartGit `<version>/` directory.
    ///
    /// SmartGit stores its data across several YAML files:
    /// - `repository-grouping.yml` — authoritative source of groups +
    ///   their member repositories (with display name and absolute path),
    ///   plus a `recentlyUsed` list of paths for ungrouped repos.
    /// - `repositories.yml` — per-repo settings keyed by the absolute path
    ///   (used as a fallback when grouping is unavailable or empty).
    /// - `credentials.yml` — URLs + usernames (passwords skipped).
    /// - `accelerators.yml` — keyboard shortcuts.
    func parse(versionDirectory: URL) async -> SmartGitConfig {
        let version = versionDirectory.lastPathComponent
        var repos: [SmartGitRepository] = []
        var credentials: [(String, String)] = []
        var shortcuts: [String: String] = [:]

        // ── Primary: repository-grouping.yml ──
        let groupingURL = versionDirectory.appendingPathComponent("repository-grouping.yml")
        var groupedPaths = Set<String>()
        if let text = try? String(contentsOf: groupingURL, encoding: .utf8),
           let parsed = try? Yams.load(yaml: text) as? [String: Any] {
            if let structure = parsed["structure"] as? [[String: Any]] {
                for group in structure {
                    let groupName = group["name"] as? String
                    let children = group["children"] as? [[String: Any]] ?? []
                    for child in children {
                        guard let path = resolvePath(from: child) else { continue }
                        let name = (child["name"] as? String)
                            ?? URL(fileURLWithPath: path).lastPathComponent
                        repos.append(SmartGitRepository(
                            path: path,
                            name: name,
                            group: groupName,
                            valid: isValidGitRepo(path: path)
                        ))
                        groupedPaths.insert(path)
                    }
                }
            }
            // recentlyUsed may include paths not in any group.
            if let recent = parsed["recentlyUsed"] as? [String] {
                for raw in recent {
                    let path = expandTilde(raw)
                    guard !groupedPaths.contains(path) else { continue }
                    repos.append(SmartGitRepository(
                        path: path,
                        name: URL(fileURLWithPath: path).lastPathComponent,
                        group: nil,
                        valid: isValidGitRepo(path: path)
                    ))
                    groupedPaths.insert(path)
                }
            }
        }

        // ── Fallback: repositories.yml ──
        // Some installs may have repositories listed only as map keys under
        // `gitRootSettingsSet` (key format: `root<absolute-path>`).
        if repos.isEmpty {
            let reposURL = versionDirectory.appendingPathComponent("repositories.yml")
            if let text = try? String(contentsOf: reposURL, encoding: .utf8),
               let parsed = try? Yams.load(yaml: text) as? [String: Any] {
                if let settings = parsed["gitRootSettingsSet"] as? [String: Any] {
                    for key in settings.keys where key.hasPrefix("root") {
                        let path = String(key.dropFirst("root".count))
                        repos.append(SmartGitRepository(
                            path: path,
                            name: URL(fileURLWithPath: path).lastPathComponent,
                            group: nil,
                            valid: isValidGitRepo(path: path)
                        ))
                    }
                }
            }
        }

        // Deduplicate by absolute path (last write wins).
        var seen = Set<String>()
        repos = repos.reversed().filter { seen.insert($0.path).inserted }.reversed()

        // ── credentials.yml ──
        let credsURL = versionDirectory.appendingPathComponent("credentials.yml")
        if let text = try? String(contentsOf: credsURL, encoding: .utf8),
           let parsed = try? Yams.load(yaml: text) as? [String: Any],
           let raw = parsed["credentials"] as? [[String: Any]] {
            for entry in raw {
                if let url = entry["url"] as? String,
                   let username = entry["username"] as? String {
                    credentials.append((url, username))
                }
            }
        }

        // ── accelerators.yml ──
        let acceleratorsURL = versionDirectory.appendingPathComponent("accelerators.yml")
        if let text = try? String(contentsOf: acceleratorsURL, encoding: .utf8),
           let parsed = try? Yams.load(yaml: text) as? [String: String] {
            shortcuts = parsed
        }

        return SmartGitConfig(
            version: version,
            configPath: versionDirectory,
            repositories: repos,
            credentials: credentials,
            shortcuts: shortcuts
        )
    }

    /// Pulls the most specific path field from a SmartGit grouping child.
    /// Prefers `path.absolute` (already resolved), falls back to `path`
    /// (which may use `~`).
    private func resolvePath(from child: [String: Any]) -> String? {
        if let abs = child["path.absolute"] as? String, !abs.isEmpty {
            return abs
        }
        if let rel = child["path"] as? String, !rel.isEmpty {
            return expandTilde(rel)
        }
        return nil
    }

    private func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let home = fm.homeDirectoryForCurrentUser.path
        return home + path.dropFirst()
    }

    private func isValidGitRepo(path: String) -> Bool {
        let gitDir = URL(fileURLWithPath: path).appendingPathComponent(".git")
        return fm.fileExists(atPath: gitDir.path)
    }

    /// Apply a parsed SmartGit config to SmallGit's repositories store.
    /// Returns a fresh `RepositoriesConfig` ready to persist.
    func materialize(
        _ config: SmartGitConfig,
        into existing: RepositoriesConfig,
        includeMissing: Bool = false
    ) -> RepositoriesConfig {
        var result = existing
        var existingPaths = Set(result.allRepositoryPaths())

        let candidates = includeMissing
            ? config.repositories
            : config.validRepositories

        for repo in candidates {
            guard !existingPaths.contains(repo.path) else { continue }
            existingPaths.insert(repo.path)
            let entry = RepositoryEntry(path: repo.path, name: repo.name)
            if let group = repo.group, !group.isEmpty {
                if let idx = result.groups.firstIndex(where: { $0.name == group }) {
                    result.groups[idx].repositories.append(entry)
                } else {
                    result.groups.append(RepositoryGroup(
                        name: group,
                        repositories: [entry]
                    ))
                }
            } else {
                result.ungrouped.append(entry)
            }
        }
        return result
    }
}

private extension RepositoriesConfig {
    func allRepositoryPaths() -> [String] {
        groups.flatMap { $0.repositories.map(\.path) } + ungrouped.map(\.path)
    }
}
