import Foundation

enum DiffLineType: String, Codable, Sendable {
    case context
    case add
    case del
    /// Used to pad the opposite side in side-by-side rendering.
    case empty
}

struct DiffLine: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let type: DiffLineType
    let content: String
    let oldLineNumber: Int?
    let newLineNumber: Int?
    /// True when git emitted "\ No newline at end of file" for this line —
    /// i.e. the file's final line has no trailing newline. Must be carried
    /// through into any patch we build for `git apply`, otherwise the patch
    /// claims a trailing newline the index doesn't have and git rejects it
    /// with "patch does not apply".
    var noNewlineAtEOF: Bool

    init(
        id: UUID = UUID(),
        type: DiffLineType,
        content: String,
        oldLineNumber: Int? = nil,
        newLineNumber: Int? = nil,
        noNewlineAtEOF: Bool = false
    ) {
        self.id = id
        self.type = type
        self.content = content
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.noNewlineAtEOF = noNewlineAtEOF
    }

    // Tolerant decode so any diff blobs cached before this field existed
    // still decode (defaulting to a normal trailing newline).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id             = try c.decode(UUID.self,   forKey: .id)
        self.type           = try c.decode(DiffLineType.self, forKey: .type)
        self.content        = try c.decode(String.self, forKey: .content)
        self.oldLineNumber  = try c.decodeIfPresent(Int.self, forKey: .oldLineNumber)
        self.newLineNumber  = try c.decodeIfPresent(Int.self, forKey: .newLineNumber)
        self.noNewlineAtEOF = try c.decodeIfPresent(Bool.self, forKey: .noNewlineAtEOF) ?? false
    }
}

struct DiffHunk: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    var lines: [DiffLine]
    /// Repo-relative path of the file this hunk belongs to, taken from the
    /// `diff --git` header above it.
    ///
    /// Needed because a stash or commit diff is several files in one stream,
    /// and the view otherwise has no way to tell which language a given row
    /// is written in. Optional, so hunks decoded from cache files written
    /// before this existed still load.
    var file: String?

    init(
        id: UUID = UUID(),
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        lines: [DiffLine] = [],
        file: String? = nil
    ) {
        self.id = id
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
        self.file = file
    }
}

/// Pairs a flat hunk list into side-by-side (old | new) rows. Shared by
/// the live Diff panel (`DiffViewModel.pairedRows`) and the read-only
/// commit compare window so both lay out modifications identically:
/// runs of `-` lines line up against the following run of `+` lines,
/// padding the shorter side with `empty` lines.
enum DiffPairing {
    static func pairs(from hunks: [DiffHunk]) -> [(left: DiffLine, right: DiffLine, hunk: DiffHunk)] {
        var pairs: [(DiffLine, DiffLine, DiffHunk)] = []
        for hunk in hunks {
            var i = 0
            let lines = hunk.lines
            while i < lines.count {
                let line = lines[i]
                switch line.type {
                case .context:
                    pairs.append((line, line, hunk))
                    i += 1
                case .del:
                    var dels: [DiffLine] = []
                    var adds: [DiffLine] = []
                    while i < lines.count, lines[i].type == .del {
                        dels.append(lines[i]); i += 1
                    }
                    while i < lines.count, lines[i].type == .add {
                        adds.append(lines[i]); i += 1
                    }
                    let maxLen = max(dels.count, adds.count)
                    for k in 0..<maxLen {
                        let l = k < dels.count ? dels[k] : DiffLine(type: .empty, content: "")
                        let r = k < adds.count ? adds[k] : DiffLine(type: .empty, content: "")
                        pairs.append((l, r, hunk))
                    }
                case .add:
                    pairs.append((DiffLine(type: .empty, content: ""), line, hunk))
                    i += 1
                case .empty:
                    i += 1
                }
            }
        }
        return pairs
    }
}

/// How the diff is laid out. This is the *layout* axis only — whether
/// unchanged context is shown is the orthogonal `compactMode` flag on
/// `DiffViewModel`, so "Compact" can combine with either layout rather
/// than being a third, mutually-exclusive mode.
enum DiffMode: String, Codable, CaseIterable, Sendable {
    case unified
    case sideBySide

    var label: String {
        switch self {
        case .unified: return "Unified"
        case .sideBySide: return "Side by Side"
        }
    }
}

/// Which two trees the diff compares — the two staged/unstaged views, like
/// SmartGit. `headVsIndex` shows what's staged, `indexVsWorkingTree` what's
/// not; per-line staging works in both. (A combined HEAD-vs-Working-Tree
/// view was dropped: it can't support partial staging, so it only confused
/// users about why "Stage Line" was disabled.)
enum DiffCompareMode: String, Codable, CaseIterable, Hashable, Sendable {
    case headVsIndex
    case indexVsWorkingTree

    var label: String {
        switch self {
        case .headVsIndex:        return "HEAD vs Index"
        case .indexVsWorkingTree: return "Index vs Working Tree"
        }
    }

    var shortLabel: String {
        switch self {
        case .headVsIndex:        return "HEAD ↔ Index"
        case .indexVsWorkingTree: return "Index ↔ Working"
        }
    }
}

enum DiffSide: Sendable {
    case old
    case new
}
