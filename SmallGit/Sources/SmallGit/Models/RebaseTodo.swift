import Foundation

/// Action for a single row in an interactive rebase plan. Mirrors the
/// keywords git's interactive rebase editor accepts. There is no `reword`:
/// a new message is carried on the row itself (`RebaseTodo.message`) and
/// applied by an `exec` amend, because git's `reword` hands the message to
/// `$GIT_EDITOR` and that editor is `true` here. `edit` is omitted because
/// it needs a pause-and-resume flow we don't have yet.
enum RebaseAction: String, Codable, Hashable, CaseIterable, Sendable {
    /// Keep the commit as-is.
    case pick
    /// Squash this commit into the preceding one. Git concatenates the two
    /// commit messages and opens the editor; with `GIT_EDITOR=true` the
    /// combined message is accepted unchanged.
    case squash
    /// Like `squash` but discards this commit's message (uses only the
    /// preceding commit's message).
    case fixup
    /// Drop the commit entirely.
    case drop

    /// The keyword git's todo parser expects.
    var keyword: String { rawValue }

    var displayName: String {
        switch self {
        case .pick:   return "Pick"
        case .squash: return "Squash"
        case .fixup:  return "Fixup"
        case .drop:   return "Drop"
        }
    }

    /// Single-letter glyph for compact display in lists.
    var glyph: String {
        switch self {
        case .pick:   return "P"
        case .squash: return "S"
        case .fixup:  return "F"
        case .drop:   return "D"
        }
    }
}

/// A single row in an interactive rebase plan. The order of `RebaseTodo`s
/// in the plan is the order git will replay them, top-to-bottom (which is
/// the inverse of `git log` order — first item is the oldest commit).
struct RebaseTodo: Identifiable, Hashable, Sendable {
    let id: String
    let hash: String
    let shortHash: String
    let subject: String
    var action: RebaseAction
    /// The message the user wrote in the planner for the commit this row
    /// ends up as — the row on its own, or the row plus every squash and
    /// fixup folded into it. Nil keeps what git would produce. Honoured only
    /// on a `pick` row: a row folded into another one has no commit of its
    /// own to carry a message.
    var message: String?

    init(
        hash: String,
        shortHash: String,
        subject: String,
        action: RebaseAction = .pick,
        message: String? = nil
    ) {
        self.id = hash
        self.hash = hash
        self.shortHash = shortHash
        self.subject = subject
        self.action = action
        self.message = message
    }

    /// One line of the `git-rebase-todo` file:
    ///     pick <hash> <subject>
    /// `drop` rows are emitted as `drop <hash> <subject>`. Comments are
    /// omitted; git ignores them anyway.
    var todoLine: String {
        "\(action.keyword) \(hash) \(subject)"
    }
}

/// What an interactive rebase onto a given base would replay — and what it
/// would silently skip.
///
/// The second half is not a detail. Rebasing onto a branch whose own history
/// was rewritten (a force-push, a squash-merge, an upstream that rebased)
/// leaves your branch carrying commits that are *already on that base* under
/// different SHAs. git recognises them by patch-id and drops them from its
/// todo; a plan that listed them would make the user drop them by hand, and
/// replay work the base already has if they didn't.
struct RebaseRange: Sendable {
    /// The commits to put in the plan, oldest first.
    let todo: [RebaseTodo]
    /// Commits git recognises as already present on the base — same change,
    /// different commit. Left out of the plan, kept so the planner can say how
    /// many disappeared and why rather than leave the user counting.
    let alreadyOnBase: [RebaseTodo]
}

/// Identifiable handle passed to `.sheet(item:)` so MainWindow can present
/// `InteractiveRebaseSheet` once `commitsToRebase` has loaded. Holds the
/// base ref the user is rebasing onto plus the seed todo (every row
/// defaults to `pick`).
struct InteractiveRebaseTarget: Identifiable, Sendable {
    let id = UUID()
    /// The ref handed to git. A branch name from the Branches panel, a full
    /// commit hash from the Journal — full, so it can't go ambiguous.
    let base: String
    /// What to call that ref on screen. Same as `base` for a branch; the
    /// short hash for a commit, since a 40-character SHA in a header reads
    /// as noise and nothing else in the app spells one out.
    let baseDisplay: String
    let initialTodo: [RebaseTodo]
    /// Commits the range held that git will not replay because the base
    /// already has them. Shown as a line in the sheet, not as rows: they are
    /// not decisions the user has to make.
    let alreadyOnBase: [RebaseTodo]

    init(
        base: String,
        baseDisplay: String? = nil,
        initialTodo: [RebaseTodo],
        alreadyOnBase: [RebaseTodo] = []
    ) {
        self.base = base
        self.baseDisplay = baseDisplay ?? base
        self.initialTodo = initialTodo
        self.alreadyOnBase = alreadyOnBase
    }
}

extension Array where Element == RebaseTodo {
    /// The full text written to git's todo file. Trailing newline is
    /// required; without it git complains about an unterminated final line.
    ///
    /// A `pick` row carrying a `message` gets an `exec` amend once its group
    /// closes — after the last squash or fixup folded into it — so the amend
    /// lands on the combined commit, not on the first half of it.
    var todoFileContents: String {
        var lines: [String] = []
        var openMessage: String?
        func closeGroup() {
            if let message = openMessage { lines.append(RebaseTodo.amendLine(message)) }
            openMessage = nil
        }
        for row in self {
            if row.action == .pick {
                closeGroup()
                openMessage = row.message
            }
            lines.append(row.todoLine)
        }
        closeGroup()
        return lines.joined(separator: "\n") + "\n"
    }

    /// The row a squash or fixup at `index` folds into: the nearest `pick`
    /// above it. Dropped rows are skipped, as git skips them, and so are the
    /// other squashes of the same group — they fold into that pick too.
    /// Nil for a row that is not folded, or folds into nothing (the plan is
    /// then invalid; see `validationError`).
    func squashTarget(of index: Int) -> Int? {
        guard indices.contains(index),
              self[index].action == .squash || self[index].action == .fixup
        else { return nil }
        var cursor = index - 1
        while cursor >= 0 {
            if self[cursor].action == .pick { return cursor }
            cursor -= 1
        }
        return nil
    }

    /// The rows folded into the `pick` at `index`, in replay order.
    func squashMembers(of index: Int) -> [Int] {
        guard indices.contains(index), self[index].action == .pick else { return [] }
        var members: [Int] = []
        var cursor = index + 1
        while cursor < count, self[cursor].action != .pick {
            if self[cursor].action != .drop { members.append(cursor) }
            cursor += 1
        }
        return members
    }

    /// The row whose message decides the commit `index` ends up in: itself
    /// for a pick, its target for a squash or fixup, nil for a drop.
    func messageOwner(of index: Int) -> Int? {
        guard indices.contains(index) else { return nil }
        switch self[index].action {
        case .pick:           return index
        case .squash, .fixup: return squashTarget(of: index)
        case .drop:           return nil
        }
    }

    /// Whether the pick at `index` takes a squash whose message the user has
    /// not looked at. Left alone, git just stacks the messages one after the
    /// other — rarely the message anyone wants on the result.
    func needsMessageReview(_ index: Int) -> Bool {
        guard indices.contains(index), self[index].message == nil else { return false }
        return squashMembers(of: index).contains { self[$0].action == .squash }
    }

    /// A plan is invalid if the first commit it keeps is `squash` or `fixup`
    /// — there is no preceding commit for git to combine into. Returns nil
    /// when valid, or a human-readable reason otherwise.
    var validationError: String? {
        guard !isEmpty else { return "The rebase plan is empty." }
        guard let first = first(where: { $0.action != .drop }) else {
            return "Every commit is set to drop. There would be nothing to rebase."
        }
        if first.action == .squash || first.action == .fixup {
            return "The first commit cannot be \(first.action.displayName.lowercased()) — there is no earlier commit to combine into."
        }
        return nil
    }
}

extension RebaseTodo {
    /// An `exec` line that rewrites the message of the commit git has just
    /// made. The message rides inside the line itself, as a `printf %b`
    /// argument (a format would trip on `%`, and on a message starting with
    /// `-`), rather than in a file: a rebase that stops on a conflict runs this
    /// line later, long after any temp file of ours would be gone, while the
    /// todo is kept by git in `.git/rebase-merge`.
    static func amendLine(_ message: String) -> String {
        let escaped = message
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
        let quoted = "'" + escaped.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "exec printf '%b' \(quoted) | git commit --amend --quiet --file=-"
    }
}

/// A finished interactive rebase whose result doesn't look like its plan —
/// most often a squash git split in two after another program took the
/// index lock mid-step. Offered back to the user with a way to undo it.
struct RebaseOutcomeMismatch: Identifiable, Sendable {
    let id = UUID()
    let originalHead: String
    let branch: String?
    let expectedCommits: Int
    let actualCommits: Int
    /// Commits still carrying git's "# This is a combination of" template.
    let leakedSquashMessages: Int

    var summary: String {
        var parts: [String] = []
        if actualCommits != expectedCommits {
            parts.append("The plan should have left \(expectedCommits) commit\(expectedCommits == 1 ? "" : "s") on top of the base, but there \(actualCommits == 1 ? "is" : "are") \(actualCommits).")
        }
        if leakedSquashMessages > 0 {
            parts.append("\(leakedSquashMessages) commit message\(leakedSquashMessages == 1 ? " still holds" : "s still hold") git's squash template.")
        }
        parts.append("A squash may have been split when another program took the index lock mid-rebase. Undo puts \(branch ?? "HEAD") back at \(String(originalHead.prefix(11))) so you can run the plan again; uncommitted changes are kept.")
        return parts.joined(separator: " ")
    }
}
