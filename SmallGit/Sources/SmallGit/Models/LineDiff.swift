import Foundation

/// One row of a side-by-side line diff. Both sides may be present
/// (`.same`), or only one (`.removed` from left, `.added` on right).
/// Line numbers are 1-based and reflect each side's own numbering —
/// when a side is absent its number is nil so the gutter renders blank.
struct CompareRow: Identifiable, Hashable, Sendable {
    let id: Int
    let leftLine: Int?
    let leftText: String?
    let rightLine: Int?
    let rightText: String?

    enum Kind: Sendable {
        case same
        case removed
        case added
        /// Both sides present and matched to each other, but not identical —
        /// they differ only in whitespace. Beyond Compare calls these minor
        /// differences; they are shown as a change, with the intra-line diff
        /// marking what moved.
        case modified
    }

    var kind: Kind {
        if let leftText, let rightText {
            return leftText == rightText ? .same : .modified
        }
        if leftText != nil { return .removed }
        return .added
    }

    var isChange: Bool { kind != .same }
}

/// A HEAD line and a WORKING line the user has said belong side by side —
/// Beyond Compare's "Align With". Indices are 0-based into each side.
///
/// No aligner gets every block right: with nothing in common between two
/// lines it has nothing to go on, and in a block of look-alike declarations
/// it can only guess which one became which. A pin settles it — the compare
/// is run separately above and below it, so the two lines land on one row
/// and everything else falls into place around them.
struct LineAlignment: Hashable, Sendable {
    let left: Int
    let right: Int

    /// Whether the two pins can hold at once: each must be above the other
    /// on both sides, or below it on both. Two pins that cross, or share a
    /// line, ask for an order the files do not have.
    func isCompatible(with other: LineAlignment) -> Bool {
        (left < other.left && right < other.right) || (left > other.left && right > other.right)
    }

    /// `pin` added to `existing`, with the pins it contradicts let go — the
    /// newest word on where a line belongs is the one that stands. Sorted.
    static func adding(_ pin: LineAlignment, to existing: [LineAlignment]) -> [LineAlignment] {
        (existing.filter { $0.isCompatible(with: pin) } + [pin]).sorted { $0.left < $1.left }
    }
}

/// Aligns two arrays of lines into a single sequence of side-by-side
/// rows using a Longest Common Subsequence (Wagner–Fischer) backtrack.
///
/// The LCS table is O(n·m), which a file with tens of thousands of changed
/// lines turns into billions of cells and gigabytes of memory — the window
/// that asked for it simply never came back. So the table only ever sees what
/// it has to: the lines both sides share at the top and bottom are paired
/// off first, and a middle still too big for `cellLimit` is split on lines
/// that occur exactly once on each side (patience diff) and the pieces
/// aligned separately. A piece with no such line to split on is shown as
/// removed-then-added, which is what a reader would make of it anyway.
///
/// What the table cannot match it still lines up: inside a changed run each
/// old line is set beside the new line most like it (see `pairChanges`), and
/// pins the user has placed (`LineAlignment`) split the work into pieces that
/// are aligned on their own.
///
/// Checks `Task.isCancelled` as it goes and returns `[]` once it is set, so
/// a caller running it in a task can abandon a compare that is taking too
/// long.
enum LineDiff {

    /// The most cells the LCS table may have — about 32 MB of `Int32`, a
    /// few tens of milliseconds to fill.
    static let cellLimit = 8_000_000

    /// Convenience: splits text on newlines, preserving an empty
    /// trailing element when the text ends with `\n` (so the line
    /// count matches what editors show).
    static func split(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    /// What two lines are matched on when aligning the sides.
    ///
    /// Whitespace-insensitive, and that is the whole point. Byte equality
    /// leaves a line whose indentation changed — or a blank line that lost
    /// its trailing spaces — with nothing to pair against, so it gets
    /// deleted at whichever end of the neighbouring insertion the backtrack
    /// happens to reach first. That is how a blank line ends up matched
    /// against `#if DEBUG` at the top of a three-line insertion instead of
    /// against the blank line at the bottom, which is the pairing a reader
    /// would make instantly.
    ///
    /// Matching on the whitespace-free key finds that pairing. The lines
    /// still render as a difference — see `Kind.modified` — so nothing is
    /// hidden by being aligned.
    static func alignmentKey(_ line: String) -> String {
        line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The most cells the similarity table of one changed run may have. Each
    /// cell compares two lines, so this is kept well under `cellLimit`; a run
    /// past it is paired top to bottom instead.
    static let closenessCellLimit = 100_000

    /// `pins` that are out of range, or out of order with the ones before
    /// them, are ignored — see `LineAlignment.adding` for keeping a set that
    /// has neither.
    static func compute(
        left: [String],
        right: [String],
        pins: [LineAlignment] = []
    ) -> [CompareRow] {
        let m = left.count
        let n = right.count

        // Fast paths for the trivial cases — both empty, one empty.
        if m == 0 && n == 0 { return [] }
        if m == 0 {
            return right.enumerated().map { idx, line in
                CompareRow(id: idx, leftLine: nil, leftText: nil, rightLine: idx + 1, rightText: line)
            }
        }
        if n == 0 {
            return left.enumerated().map { idx, line in
                CompareRow(id: idx, leftLine: idx + 1, leftText: line, rightLine: nil, rightText: nil)
            }
        }

        // Keys are computed once up front: the table is O(n·m), and
        // normalising inside it would make that O(n·m·length).
        var aligner = Aligner(
            leftKeys: left.map(alignmentKey),
            rightKeys: right.map(alignmentKey)
        )
        var i = 0, j = 0
        for pin in pins where pin.left >= i && pin.right >= j && pin.left < m && pin.right < n {
            aligner.alignPiece(i..<pin.left, j..<pin.right)
            aligner.pin(pin)
            i = pin.left + 1; j = pin.right + 1
        }
        aligner.alignPiece(i..<m, j..<n)
        if Task.isCancelled { return [] }

        // IDs in forward order so SwiftUI's diffing is stable and
        // `.scrollTo(id:)` lands on a known target.
        return aligner.steps.enumerated().map { idx, step in
            CompareRow(
                id: idx,
                leftLine: step.left.map { $0 + 1 }, leftText: step.left.map { left[$0] },
                rightLine: step.right.map { $0 + 1 }, rightText: step.right.map { right[$0] }
            )
        }
    }

    /// One aligned row by index into each side; nil where the side has no
    /// line in it.
    private struct Step {
        let left: Int?
        let right: Int?
    }

    private struct Aligner {
        let leftKeys: [String]
        let rightKeys: [String]
        /// In forward order. Within a changed run a replaced line comes
        /// immediately before its replacement — removed, then added — which
        /// is what the compare view draws as one row with a word diff. A
        /// line with no partner is never followed by one from the other side
        /// that has none either (see `pairChanges`), so no two lines read as
        /// a pair that were not made one.
        var steps: [Step] = []

        init(leftKeys: [String], rightKeys: [String]) {
            self.leftKeys = leftKeys
            self.rightKeys = rightKeys
            steps.reserveCapacity(max(leftKeys.count, rightKeys.count))
        }

        /// One stretch between two pins, or the whole file when there are
        /// none: aligned, then its changed runs paired up. Paired per stretch
        /// so a run never reaches across a pin and re-pairs its lines.
        mutating func alignPiece(_ a: Range<Int>, _ b: Range<Int>) {
            let start = steps.count
            align(a, b)
            pairChanges(from: start)
        }

        /// The two lines of a pin, on one row. Lines that differ go in as the
        /// removed-then-added pair the view draws side by side; lines that
        /// match apart from whitespace are simply matched.
        mutating func pin(_ pin: LineAlignment) {
            if leftKeys[pin.left] == rightKeys[pin.right] {
                steps.append(Step(left: pin.left, right: pin.right))
            } else {
                steps.append(Step(left: pin.left, right: nil))
                steps.append(Step(left: nil, right: pin.right))
            }
        }

        /// Pairs the lines of each changed run in `steps[start...]` — Beyond
        /// Compare's closeness matching.
        ///
        /// The table leaves a run as its old lines and its new ones with no
        /// word on which became which, and the view used to pair only where
        /// the two lists met: the *last* old line with the *first* new one.
        /// Two lines that each gained a parameter came out with the second
        /// old one beside the first new one, and the other two beside
        /// nothing.
        ///
        /// Every line of the shorter side gets a partner, in order, and the
        /// longer side's spare lines go wherever that pairs the most similar
        /// lines (`bestPairing`). As many pairs as possible is what keeps
        /// the output honest: with it, no gap between two pairs holds spare
        /// lines from both sides, so the view's adjacent pairing can never
        /// join two lines this did not.
        private mutating func pairChanges(from start: Int) {
            guard start < steps.count, !Task.isCancelled else { return }
            var out: [Step] = []
            out.reserveCapacity(steps.count - start)
            var k = start
            while k < steps.count {
                guard steps[k].left == nil || steps[k].right == nil else {
                    out.append(steps[k])
                    k += 1
                    continue
                }
                var lefts: [Int] = [], rights: [Int] = []
                while k < steps.count, steps[k].left == nil || steps[k].right == nil {
                    if let l = steps[k].left { lefts.append(l) }
                    if let r = steps[k].right { rights.append(r) }
                    k += 1
                }
                emitRun(lefts, rights, into: &out)
            }
            steps.replaceSubrange(start..., with: out)
        }

        private func emitRun(_ lefts: [Int], _ rights: [Int], into out: inout [Step]) {
            let pairs = bestPairing(lefts, rights)
            var l = 0, r = 0
            for (pl, pr) in pairs {
                while l < pl { out.append(Step(left: lefts[l], right: nil)); l += 1 }
                while r < pr { out.append(Step(left: nil, right: rights[r])); r += 1 }
                out.append(Step(left: lefts[l], right: nil))
                out.append(Step(left: nil, right: rights[r]))
                l += 1; r += 1
            }
            while l < lefts.count { out.append(Step(left: lefts[l], right: nil)); l += 1 }
            while r < rights.count { out.append(Step(left: nil, right: rights[r])); r += 1 }
        }

        /// Which lines of a run to pair, as positions into `lefts` and
        /// `rights`, in order. Pairs `min(lefts, rights)` lines; when the
        /// sides differ in length, the spare lines of the longer one are
        /// placed to make the pairs as alike as they can be. Ties keep the
        /// pairs at the top, which is also the answer for a run too big to
        /// weigh.
        private func bestPairing(_ lefts: [Int], _ rights: [Int]) -> [(Int, Int)] {
            let leftIsShort = lefts.count <= rights.count
            let short = leftIsShort ? lefts.count : rights.count
            let spare = (leftIsShort ? rights.count : lefts.count) - short
            guard short > 0 else { return [] }
            func pair(_ s: Int, _ t: Int) -> (Int, Int) { leftIsShort ? (s, t) : (t, s) }

            guard spare > 0, (short + 1) * (spare + 1) <= LineDiff.closenessCellLimit else {
                return (0..<short).map { pair($0, $0) }
            }
            let shortGrams = (leftIsShort ? lefts : rights).map {
                LineDiff.bigrams(leftIsShort ? leftKeys[$0] : rightKeys[$0])
            }
            let longGrams = (leftIsShort ? rights : lefts).map {
                LineDiff.bigrams(leftIsShort ? rightKeys[$0] : leftKeys[$0])
            }

            // `score[s][o]`: best total for the first `s` short lines, paired
            // within the first `s + o` long ones — `o` of those left spare.
            let width = spare + 1
            var score = [Int](repeating: 0, count: (short + 1) * width)
            for s in 1...short {
                for o in 0...spare {
                    let take = score[(s - 1) * width + o]
                        + LineDiff.similarity(shortGrams[s - 1], longGrams[s + o - 1])
                    let skip = o > 0 ? score[s * width + o - 1] : Int.min
                    score[s * width + o] = max(take, skip)
                }
            }
            // Back from the end. Spare lines are taken off the bottom first
            // when it costs nothing, which is what keeps ties at the top.
            var pairs: [(Int, Int)] = []
            var s = short, o = spare
            while s > 0 {
                if o > 0, score[s * width + o - 1] == score[s * width + o] {
                    o -= 1
                } else {
                    pairs.append(pair(s - 1, s + o - 1))
                    s -= 1
                }
            }
            return pairs.reversed()
        }

        mutating func align(_ a: Range<Int>, _ b: Range<Int>) {
            if Task.isCancelled { return }
            var lo1 = a.lowerBound, lo2 = b.lowerBound
            while lo1 < a.upperBound, lo2 < b.upperBound, leftKeys[lo1] == rightKeys[lo2] {
                steps.append(Step(left: lo1, right: lo2))
                lo1 += 1; lo2 += 1
            }
            var hi1 = a.upperBound, hi2 = b.upperBound
            while hi1 > lo1, hi2 > lo2, leftKeys[hi1 - 1] == rightKeys[hi2 - 1] {
                hi1 -= 1; hi2 -= 1
            }
            let midA = lo1..<hi1, midB = lo2..<hi2

            if midA.isEmpty || midB.isEmpty {
                unmatched(midA, midB)
            } else if midA.count * midB.count <= LineDiff.cellLimit {
                lcs(midA, midB)
            } else {
                let anchors = uniqueAnchors(midA, midB)
                if anchors.isEmpty {
                    unmatched(midA, midB)
                } else {
                    var i = midA.lowerBound, j = midB.lowerBound
                    for (ai, bj) in anchors {
                        align(i..<ai, j..<bj)
                        steps.append(Step(left: ai, right: bj))
                        i = ai + 1; j = bj + 1
                    }
                    align(i..<midA.upperBound, j..<midB.upperBound)
                }
            }

            for k in 0..<(a.upperBound - hi1) {
                steps.append(Step(left: hi1 + k, right: hi2 + k))
            }
        }

        private mutating func unmatched(_ a: Range<Int>, _ b: Range<Int>) {
            for i in a { steps.append(Step(left: i, right: nil)) }
            for j in b { steps.append(Step(left: nil, right: j)) }
        }

        /// The Wagner–Fischer table and its backtrack, over one piece.
        private mutating func lcs(_ a: Range<Int>, _ b: Range<Int>) {
            let m = a.count, n = b.count
            let width = n + 1
            var dp = [Int32](repeating: 0, count: (m + 1) * width)
            for i in 1...m {
                if Task.isCancelled { return }
                let key = leftKeys[a.lowerBound + i - 1]
                for j in 1...n {
                    if key == rightKeys[b.lowerBound + j - 1] {
                        dp[i * width + j] = dp[(i - 1) * width + j - 1] + 1
                    } else {
                        dp[i * width + j] = max(dp[(i - 1) * width + j], dp[i * width + j - 1])
                    }
                }
            }

            // Walk from the bottom-right corner; at each step either consume
            // a matching pair, or one side ahead of the other. Collected
            // backwards and reversed on the way out.
            var piece: [Step] = []
            piece.reserveCapacity(m + n)
            var i = m, j = n
            while i > 0 || j > 0 {
                if i > 0, j > 0, leftKeys[a.lowerBound + i - 1] == rightKeys[b.lowerBound + j - 1] {
                    piece.append(Step(left: a.lowerBound + i - 1, right: b.lowerBound + j - 1))
                    i -= 1; j -= 1
                } else if j > 0 && (i == 0 || dp[i * width + j - 1] >= dp[(i - 1) * width + j]) {
                    piece.append(Step(left: nil, right: b.lowerBound + j - 1))
                    j -= 1
                } else {
                    piece.append(Step(left: a.lowerBound + i - 1, right: nil))
                    i -= 1
                }
            }
            steps.append(contentsOf: piece.reversed())
        }

        /// Lines that occur exactly once on each side, paired, and cut down
        /// to the longest run that is in order on both — patience diff's
        /// anchors. Sorted by position.
        private func uniqueAnchors(_ a: Range<Int>, _ b: Range<Int>) -> [(Int, Int)] {
            // Per key: occurrences on each side and where the single one is.
            var seen: [String: (left: Int, leftAt: Int, right: Int, rightAt: Int)] = [:]
            for i in a {
                let old = seen[leftKeys[i]] ?? (0, 0, 0, 0)
                seen[leftKeys[i]] = (old.left + 1, i, old.right, old.rightAt)
            }
            for j in b {
                guard let old = seen[rightKeys[j]] else { continue }
                seen[rightKeys[j]] = (old.left, old.leftAt, old.right + 1, j)
            }
            let pairs = seen.values
                .filter { $0.left == 1 && $0.right == 1 }
                .map { ($0.leftAt, $0.rightAt) }
                .sorted { $0.0 < $1.0 }
            if pairs.isEmpty || Task.isCancelled { return [] }

            // Longest increasing run of right-hand positions, by patience
            // sorting: `tails[k]` is the pair ending the best run of length
            // k + 1, `back` links each pair to the one before it.
            var tails: [Int] = []
            var back = [Int](repeating: -1, count: pairs.count)
            for (idx, pair) in pairs.enumerated() {
                var lo = 0, hi = tails.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if pairs[tails[mid]].1 < pair.1 { lo = mid + 1 } else { hi = mid }
                }
                if lo > 0 { back[idx] = tails[lo - 1] }
                if lo == tails.count { tails.append(idx) } else { tails[lo] = idx }
            }
            var run: [(Int, Int)] = []
            var cursor = tails.last ?? -1
            while cursor >= 0 {
                run.append(pairs[cursor])
                cursor = back[cursor]
            }
            return run.reversed()
        }
    }

    /// A line's adjacent character pairs, sorted — what `similarity` counts
    /// in common. A one-character line is its one character.
    static func bigrams(_ key: String) -> [UInt64] {
        let scalars = key.unicodeScalars.map { UInt64($0.value) }
        guard scalars.count > 1 else { return scalars }
        return (1..<scalars.count).map { scalars[$0 - 1] << 32 | scalars[$0] }.sorted()
    }

    /// How alike two lines are, 0 to 1000: the share of their character pairs
    /// they have in common (Dice's coefficient).
    static func similarity(_ a: [UInt64], _ b: [UInt64]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return a.isEmpty && b.isEmpty ? 1000 : 0 }
        var i = 0, j = 0, common = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                common += 1; i += 1; j += 1
            } else if a[i] < b[j] {
                i += 1
            } else {
                j += 1
            }
        }
        return 2000 * common / (a.count + b.count)
    }

    /// Indices into the row array where a change starts (i.e. a
    /// non-`.same` row that follows a `.same` row or sits at the top).
    /// Used by the "next / prev change" navigation buttons to jump
    /// to hunk boundaries rather than stepping line by line.
    static func changeAnchors(in rows: [CompareRow]) -> [Int] {
        var anchors: [Int] = []
        var prevWasChange = false
        for (idx, row) in rows.enumerated() {
            if row.isChange && !prevWasChange {
                anchors.append(idx)
            }
            prevWasChange = row.isChange
        }
        return anchors
    }
}

// MARK: - Collapse unchanged regions

/// One entry in the user-facing displayed list. Either a literal row
/// or a "fold" placeholder marking a contiguous run of unchanged
/// lines that we collapsed to keep the diff readable on long files.
enum DiffDisplayRow: Hashable, Sendable {
    case row(Int)                     // index into the [CompareRow] array
    case fold(start: Int, count: Int) // [start, start + count) is hidden

    var id: String {
        switch self {
        case .row(let i):              return "R\(i)"
        case .fold(let s, let c):      return "F\(s)-\(c)"
        }
    }
}

extension LineDiff {

    /// The row spans the compare view edits and copies in: a run of changes
    /// plus the context kept either side, merged where two runs' context
    /// touches.
    ///
    /// Read back out of `collapse` rather than worked out beside it. The runs
    /// it keeps between its fold markers *are* the sections, and two pieces
    /// of code deciding that separately would eventually disagree about where
    /// one ends — which is where an editor would open over rows the user
    /// cannot see.
    static func sections(rows: [CompareRow], contextLines: Int) -> [ClosedRange<Int>] {
        // A section is built around a change. With none, `collapse` hands
        // back the whole file — correct for drawing it, and exactly wrong
        // here: it would make one click open every line of the file in a
        // single editor. No changes, no sections; a line clicked on its own
        // is a line of its own.
        guard rows.contains(where: \.isChange) else { return [] }

        var out: [ClosedRange<Int>] = []
        var start: Int?
        var previous: Int?
        for entry in collapse(rows: rows, contextLines: contextLines, revealed: []) {
            switch entry {
            case .row(let idx):
                if start == nil { start = idx }
                previous = idx
            case .fold:
                if let start, let previous { out.append(start...previous) }
                start = nil
                previous = nil
            }
        }
        if let start, let previous { out.append(start...previous) }
        return out
    }

    /// Where a section's working side has nothing to show, in rows.
    ///
    /// `hasWorkingLine` is one entry per *drawn* row of the section, saying
    /// whether the working file has a line there. Entry `k` of the result is
    /// how many blank rows belong before working line `k`, with a trailing
    /// entry for the ones past the last — so a section holding lines only
    /// HEAD has keeps their space open in the middle, where they are, rather
    /// than collecting it at the end.
    ///
    /// Rows, not characters: filler lines in the editor's own text would put
    /// content in front of the user that is not in the file, and every rule
    /// for taking them out again on save can be made to eat a real line that
    /// happens to look like one.
    static func gapRows(hasWorkingLine: [Bool]) -> [Int] {
        let count = hasWorkingLine.filter { $0 }.count
        var gaps = [Int](repeating: 0, count: count + 1)
        var line = 0
        for present in hasWorkingLine {
            if present {
                line += 1
            } else {
                gaps[line] += 1
            }
        }
        return gaps.contains(where: { $0 > 0 }) ? gaps : []
    }

    /// Collapses runs of unchanged rows when they're longer than
    /// `2 * contextLines + 1`. Each kept block of changes keeps up to
    /// `contextLines` unchanged neighbours on either side; the rest
    /// becomes a single fold marker the user can expand by ID.
    ///
    /// `revealed`: row indices the user has pulled out of a fold
    /// to expand. When a fold's `id` is in this set the function
    /// emits the actual rows instead of the placeholder, so expanded
    /// regions get inlined seamlessly.
    static func collapse(
        rows: [CompareRow],
        contextLines: Int = 3,
        revealed: Set<Int> = []
    ) -> [DiffDisplayRow] {
        guard !rows.isEmpty else { return [] }

        // Build a "keep" mask: every changed row, plus contextLines
        // before and after each changed row.
        var keep = Array(repeating: false, count: rows.count)
        for (idx, row) in rows.enumerated() where row.isChange {
            let lo = max(0, idx - contextLines)
            let hi = min(rows.count - 1, idx + contextLines)
            for k in lo...hi { keep[k] = true }
        }
        // Lines the user has expanded into view. Held as indices rather
        // than as "this fold is open" so a fold can be opened a few lines
        // at a time: revealing ten of four hundred leaves a smaller fold
        // behind, which is the whole point of expanding by degrees.
        for index in revealed where rows.indices.contains(index) {
            keep[index] = true
        }

        // No changes anywhere — show the whole file as-is.
        if !keep.contains(true) {
            return rows.indices.map { .row($0) }
        }

        // Walk and emit either rows (kept) or fold markers (runs of
        // dropped). Expanded folds are inlined as rows.
        var out: [DiffDisplayRow] = []
        var i = 0
        while i < rows.count {
            if keep[i] {
                out.append(.row(i))
                i += 1
            } else {
                let start = i
                while i < rows.count && !keep[i] { i += 1 }
                let count = i - start
                let fold = DiffDisplayRow.fold(start: start, count: count)
                // A marker that hides a single line takes up the row it
                // saves, and asks for a click to get the line back. Show it.
                // Common with no context at all, where two changes a line
                // apart would otherwise be split by a fold advertising one
                // hidden line.
                if count == 1 {
                    out.append(.row(start))
                } else {
                    out.append(fold)
                }
            }
        }
        return out
    }
}

// MARK: - Intra-line (word) diff

/// One span within a single line. Used to highlight the characters
/// that actually changed when a removed line is immediately followed
/// by an added line — Beyond-Compare's pink-on-red overlay effect.
struct DiffSpan: Hashable, Sendable {
    let text: String
    let kind: Kind

    enum Kind: Sendable { case same, changed }
}

enum WordDiff {

    /// Splits a line into tokens for word-level diffing. Each whitespace
    /// run is its own token, each identifier is its own token, and
    /// every other character is its own token. That granularity makes
    /// highlights land on "the renamed identifier" rather than on
    /// "everything from the first differing char to the EOL."
    static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var currentKind: TokenKind? = nil
        for ch in s {
            let k = kind(ch)
            if k == currentKind && k != .punct {
                current.append(ch)
            } else {
                if !current.isEmpty { out.append(current) }
                current = String(ch)
                currentKind = k
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private enum TokenKind { case word, space, punct }

    private static func kind(_ c: Character) -> TokenKind {
        if c.isLetter || c.isNumber || c == "_" { return .word }
        if c.isWhitespace { return .space }
        return .punct
    }

    /// LCS-based alignment of two token streams. Returns the spans
    /// for each side, in original order, with each span marked
    /// `.same` (matched in both) or `.changed` (present in this side
    /// but missing or different in the other).
    static func diff(left: String, right: String) -> (left: [DiffSpan], right: [DiffSpan]) {
        let a = tokenize(left)
        let b = tokenize(right)
        let m = a.count, n = b.count
        if m == 0 {
            return ([], mergeAdjacent(b.map { DiffSpan(text: $0, kind: .changed) }))
        }
        if n == 0 {
            return (mergeAdjacent(a.map { DiffSpan(text: $0, kind: .changed) }), [])
        }
        // A minified line is one line of tens of thousands of tokens, and the
        // table below is their product. Past `tokenCellLimit` the shared
        // start and end are kept and everything between is marked changed —
        // coarser, but it comes back.
        if m * n > tokenCellLimit {
            return coarseDiff(a, b)
        }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        var leftSpans: [DiffSpan] = []
        var rightSpans: [DiffSpan] = []
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0, j > 0, a[i - 1] == b[j - 1] {
                leftSpans.append(DiffSpan(text: a[i - 1], kind: .same))
                rightSpans.append(DiffSpan(text: b[j - 1], kind: .same))
                i -= 1; j -= 1
            } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                rightSpans.append(DiffSpan(text: b[j - 1], kind: .changed))
                j -= 1
            } else {
                leftSpans.append(DiffSpan(text: a[i - 1], kind: .changed))
                i -= 1
            }
        }
        return (left: mergeAdjacent(leftSpans.reversed()),
                right: mergeAdjacent(rightSpans.reversed()))
    }

    /// The most cells a word-level table may have.
    static let tokenCellLimit = 250_000

    /// Shared leading and trailing tokens as `.same`, the rest `.changed`.
    private static func coarseDiff(_ a: [String], _ b: [String]) -> (left: [DiffSpan], right: [DiffSpan]) {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        func spans(_ tokens: [String]) -> [DiffSpan] {
            let parts: [(ArraySlice<String>, DiffSpan.Kind)] = [
                (tokens[..<prefix], .same),
                (tokens[prefix..<(tokens.count - suffix)], .changed),
                (tokens[(tokens.count - suffix)...], .same)
            ]
            return parts.filter { !$0.0.isEmpty }.map { DiffSpan(text: $0.0.joined(), kind: $0.1) }
        }
        return (spans(a), spans(b))
    }

    /// Collapses runs of same-kind spans so the renderer emits one
    /// styled span per run instead of one per token.
    private static func mergeAdjacent<S: Sequence>(_ spans: S) -> [DiffSpan]
        where S.Element == DiffSpan
    {
        var out: [DiffSpan] = []
        for span in spans {
            if let last = out.last, last.kind == span.kind {
                out[out.count - 1] = DiffSpan(text: last.text + span.text, kind: span.kind)
            } else {
                out.append(span)
            }
        }
        return out
    }
}
