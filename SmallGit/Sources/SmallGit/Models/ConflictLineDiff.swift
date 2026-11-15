import Foundation

enum ConflictLineSide: Int, CaseIterable, Hashable, Sendable {
    case ours
    case base
    case theirs
}

struct ConflictLineCell: Hashable, Sendable {
    let lineNumber: Int
    let text: String
}

/// One globally aligned row in the resolver's Ours / Base / Theirs view.
/// A nil cell is genuine absence, not an empty source line, and is rendered
/// with the same diagonal hatch as the two-way Compare view.
struct ConflictLineRow: Identifiable, Hashable, Sendable {
    let id: Int
    let ours: ConflictLineCell?
    let base: ConflictLineCell?
    let theirs: ConflictLineCell?
    let isChange: Bool

    func cell(for side: ConflictLineSide) -> ConflictLineCell? {
        switch side {
        case .ours: ours
        case .base: base
        case .theirs: theirs
        }
    }
}

enum ConflictDiffDisplayRow: Hashable, Sendable {
    case row(Int)
    case fold(start: Int, count: Int)

    var id: String {
        switch self {
        case .row(let index): return "R\(index)"
        case .fold(let start, let count): return "F\(start)-\(count)"
        }
    }
}

/// Aligns the resolver's three immutable versions around BASE.
///
/// Two ordinary `LineDiff` passes establish where Ours and Theirs sit relative
/// to each base line. Insertions at the same base boundary are then aligned
/// against each other, producing one shared row sequence for all three panes.
/// That shared sequence is what makes synchronized scrolling, folding, line
/// numbers, and absent-row hatching deterministic.
enum ConflictLineDiff {
    static func compute(
        base: [String],
        ours: [String],
        theirs: [String],
        hasBase: Bool
    ) -> [ConflictLineRow] {
        let effectiveBase = hasBase ? base : []
        let oursMap = decompose(base: effectiveBase, side: ours)
        let theirsMap = decompose(base: effectiveBase, side: theirs)

        var rows: [ConflictLineRow] = []
        for boundary in 1...(effectiveBase.count + 1) {
            appendInsertions(
                ours: oursMap.insertions[boundary] ?? [],
                theirs: theirsMap.insertions[boundary] ?? [],
                hasBase: hasBase,
                to: &rows
            )

            guard boundary <= effectiveBase.count else { continue }
            let baseCell = ConflictLineCell(
                lineNumber: boundary,
                text: effectiveBase[boundary - 1]
            )
            let oursCell = oursMap.byBaseLine[boundary]
            let theirsCell = theirsMap.byBaseLine[boundary]
            rows.append(makeRow(
                id: rows.count,
                ours: oursCell,
                base: baseCell,
                theirs: theirsCell,
                hasBase: hasBase
            ))
        }
        return rows
    }

    static func changeAnchors(in rows: [ConflictLineRow]) -> [Int] {
        var anchors: [Int] = []
        var previousWasChange = false
        for (index, row) in rows.enumerated() {
            if row.isChange, !previousWasChange { anchors.append(index) }
            previousWasChange = row.isChange
        }
        return anchors
    }

    static func collapse(
        rows: [ConflictLineRow],
        contextLines: Int = 3,
        expandedFolds: Set<String> = []
    ) -> [ConflictDiffDisplayRow] {
        guard !rows.isEmpty else { return [] }

        var keep = Array(repeating: false, count: rows.count)
        for (index, row) in rows.enumerated() where row.isChange {
            let lower = max(0, index - contextLines)
            let upper = min(rows.count - 1, index + contextLines)
            for keptIndex in lower...upper { keep[keptIndex] = true }
        }

        // As in Compare, a document with no differences stays readable in
        // full instead of collapsing into one unhelpful placeholder.
        guard keep.contains(true) else {
            return rows.indices.map { .row($0) }
        }

        var display: [ConflictDiffDisplayRow] = []
        var index = 0
        while index < rows.count {
            if keep[index] {
                display.append(.row(index))
                index += 1
                continue
            }

            let start = index
            while index < rows.count, !keep[index] { index += 1 }
            let count = index - start
            let fold = ConflictDiffDisplayRow.fold(start: start, count: count)
            if count == 1 || expandedFolds.contains(fold.id) {
                for rowIndex in start..<(start + count) {
                    display.append(.row(rowIndex))
                }
            } else {
                display.append(fold)
            }
        }
        return display
    }

    private struct SideMap {
        var byBaseLine: [Int: ConflictLineCell] = [:]
        var insertions: [Int: [ConflictLineCell]] = [:]
    }

    private static func decompose(base: [String], side: [String]) -> SideMap {
        let aligned = LineDiff.compute(left: base, right: side)
        var result = SideMap()
        var nextBaseLine = 1
        var index = 0

        while index < aligned.count {
            let row = aligned[index]

            // Match Compare's presentation of a replacement: an adjacent
            // remove/add pair occupies one visual row, not one absent row on
            // either side. `LineDiff` puts each replaced line immediately
            // before its replacement, and only there — an added line
            // followed by a removed one is two separate changes.
            if index + 1 < aligned.count {
                let next = aligned[index + 1]
                if let baseLine = row.leftLine,
                   row.rightLine == nil,
                   next.leftLine == nil,
                   let sideLine = next.rightLine,
                   let text = next.rightText {
                    result.byBaseLine[baseLine] = ConflictLineCell(
                        lineNumber: sideLine,
                        text: text
                    )
                    nextBaseLine = baseLine + 1
                    index += 2
                    continue
                }
            }

            if let baseLine = row.leftLine {
                if let sideLine = row.rightLine, let text = row.rightText {
                    result.byBaseLine[baseLine] = ConflictLineCell(
                        lineNumber: sideLine,
                        text: text
                    )
                }
                nextBaseLine = baseLine + 1
            } else if let sideLine = row.rightLine, let text = row.rightText {
                result.insertions[nextBaseLine, default: []].append(
                    ConflictLineCell(lineNumber: sideLine, text: text)
                )
            }
            index += 1
        }
        return result
    }

    private static func appendInsertions(
        ours: [ConflictLineCell],
        theirs: [ConflictLineCell],
        hasBase: Bool,
        to rows: inout [ConflictLineRow]
    ) {
        let alignment = LineDiff.compute(
            left: ours.map(\.text),
            right: theirs.map(\.text)
        )
        var index = 0
        while index < alignment.count {
            let aligned = alignment[index]
            if index + 1 < alignment.count {
                let next = alignment[index + 1]
                if let oursLine = aligned.leftLine,
                   aligned.rightLine == nil,
                   next.leftLine == nil,
                   let theirsLine = next.rightLine {
                    rows.append(makeRow(
                        id: rows.count,
                        ours: ours[oursLine - 1],
                        base: nil,
                        theirs: theirs[theirsLine - 1],
                        hasBase: hasBase
                    ))
                    index += 2
                    continue
                }
            }

            let oursCell = aligned.leftLine.map { ours[$0 - 1] }
            let theirsCell = aligned.rightLine.map { theirs[$0 - 1] }
            rows.append(makeRow(
                id: rows.count,
                ours: oursCell,
                base: nil,
                theirs: theirsCell,
                hasBase: hasBase
            ))
            index += 1
        }
    }

    private static func makeRow(
        id: Int,
        ours: ConflictLineCell?,
        base: ConflictLineCell?,
        theirs: ConflictLineCell?,
        hasBase: Bool
    ) -> ConflictLineRow {
        let isChange: Bool
        if hasBase {
            // An insertion has no BASE cell and is always a change. For a
            // base-backed row, either side missing or differing is a change.
            isChange = base == nil
                || ours?.text != base?.text
                || theirs?.text != base?.text
        } else {
            // Add/add conflict: there is no ancestor, so Ours and Theirs are
            // the only meaningful comparison.
            isChange = ours?.text != theirs?.text
        }
        return ConflictLineRow(
            id: id,
            ours: ours,
            base: base,
            theirs: theirs,
            isChange: isChange
        )
    }
}

/// What the merged file ends up holding at one aligned row — the fourth line
/// of the resolver's line inspector.
///
/// The three panes say what each side has at a row. This says what the file
/// will have, which is the question actually being asked when a conflict is
/// read line by line: is anything changing here, and to what.
enum ConflictRowOutcome: Hashable, Sendable {
    /// Outside every conflict. All three sides agree, so the merged file
    /// keeps the line as it stands.
    case unchanged(String)
    /// Inside a resolved chunk: the lines this row contributes — two of them
    /// when both sides were kept, none when the side that won has no line
    /// here.
    case resolved([String])
    /// The same, but the merged pane no longer says what the buttons chose:
    /// these are the lines actually in the file, typed there by hand.
    case edited([String])
    /// This row cannot be pointed at a line of the merged pane — usually
    /// because a hand edit added or removed lines, so every index past it is
    /// a guess about which line the row became. A guess is worse here than
    /// saying so.
    case unmappable
    /// Inside a chunk resolved to "neither": the region is deleted, so
    /// nothing lands here at all.
    case removed
    /// Inside a chunk nobody has decided yet. There is no answer to show —
    /// the merged file still has this chunk's markers in it.
    case undecided

    static func compute(
        row: ConflictLineRow,
        chunkID: UUID?,
        resolution: ConflictChunk.Resolution
    ) -> ConflictRowOutcome {
        guard chunkID != nil else {
            // Context: whichever side holds the row, they all hold the same
            // thing, which is why it is not part of a conflict.
            return .unchanged(row.ours?.text ?? row.base?.text ?? row.theirs?.text ?? "")
        }
        func lines(_ side: ConflictLineSide) -> [String] {
            row.cell(for: side).map { [$0.text] } ?? []
        }
        switch resolution {
        case .unresolved:      return .undecided
        case .ours:            return .resolved(lines(.ours))
        case .base:            return .resolved(lines(.base))
        case .theirs:          return .resolved(lines(.theirs))
        case .bothOursFirst:   return .resolved(lines(.ours) + lines(.theirs))
        case .bothTheirsFirst: return .resolved(lines(.theirs) + lines(.ours))
        case .neither:         return .removed
        }
    }
}
