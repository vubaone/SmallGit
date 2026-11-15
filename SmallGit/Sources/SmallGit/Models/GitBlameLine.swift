import Foundation

/// One line of `git blame` output: the source line plus the commit that
/// last touched it. Built from `git blame --line-porcelain`, which repeats
/// the full author block for every line (unlike `--porcelain`), so each
/// line is self-contained and parsing needs no carry-over state.
struct GitBlameLine: Identifiable, Hashable, Sendable {
    /// Final line number in the current file (1-based).
    let lineNumber: Int
    let commitHash: String
    let shortHash: String
    let author: String
    let date: Date?
    /// Commit subject, for the gutter tooltip.
    let summary: String
    /// The source line content (without the leading TAB git emits).
    let content: String
    /// `true` for a boundary commit (the start of available history).
    let isBoundary: Bool

    var id: Int { lineNumber }
}
