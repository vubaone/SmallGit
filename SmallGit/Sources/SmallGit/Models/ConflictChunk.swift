import Foundation

/// One `<<<<<<< / ======= / >>>>>>>` block parsed out of a conflicted
/// working-tree file. Captures the three sides plus the exact marker
/// block text so a resolution can be substituted back in by string
/// replacement without re-parsing.
struct ConflictChunk: Identifiable, Hashable {
    let id = UUID()

    /// 1-based index for "Chunk N of M" display.
    let index: Int

    /// Verbatim chunk text including markers — `<<<<<<<` to `>>>>>>>`.
    /// Used as the search needle when applying a resolution into the
    /// merged buffer; if the user edits this block by hand the search
    /// fails harmlessly (we no-op rather than corrupt their edit).
    let originalBlock: String

    /// 1-based starting line of `originalBlock` in the parsed source.
    /// Drives "scroll to chunk N" navigation in the merged editor.
    let startLineInOriginal: Int

    let oursText: String
    let baseText: String?
    let theirsText: String

    enum Resolution: String, Codable, Hashable {
        case unresolved
        case ours
        /// The common ancestor — Beyond Compare's "Take Center", KDiff3's
        /// "A". Only offerable when the conflict was written in diff3 style,
        /// since git's default markers carry no base section.
        case base
        case theirs
        case bothOursFirst
        case bothTheirsFirst
        /// Delete the conflicting lines outright. Distinct from `base`:
        /// this leaves nothing behind, that restores the original.
        case neither
    }

    /// Text that replaces `originalBlock` when this chunk is resolved.
    /// Each branch preserves trailing newlines exactly as git wrote
    /// them — the chunk content already includes a final `\n`, so we
    /// don't add or strip one here.
    func resolvedText(_ res: Resolution) -> String {
        switch res {
        case .unresolved:       return originalBlock
        case .ours:             return oursText
        // Leaves the chunk untouched rather than deleting it when the
        // conflict has no base section. The UI does not offer `.base` in
        // that case, so this only guards against a stored resolution
        // outliving the style its file was written in.
        case .base:             return baseText ?? originalBlock
        case .theirs:           return theirsText
        case .bothOursFirst:    return oursText + theirsText
        case .bothTheirsFirst:  return theirsText + oursText
        case .neither:          return ""
        }
    }
}

enum ConflictParser {
    /// Splits `text` into the inter-chunk segments plus the parsed
    /// chunks. Reassembling `segments[0] + chunks[0].originalBlock +
    /// segments[1] + chunks[1].originalBlock + …` reproduces `text`
    /// exactly. Supports diff3-style conflicts (with `|||||||` base
    /// section) and falls back to a missing base for the plain style.
    static func parse(_ text: String) -> (segments: [String], chunks: [ConflictChunk]) {
        // Hand-rolled scanner — easier to reason about than regex over
        // newline boundaries, and we need precise line indexing for
        // navigation anyway.
        var segments: [String] = []
        var chunks: [ConflictChunk] = []

        let lines = text.components(separatedBy: "\n")
        // `components(separatedBy:)` produces N+1 entries for N
        // newlines; the trailing one is empty when the file ends with
        // `\n`. We track that so the rebuilt text round-trips.

        var currentSegmentLines: [String] = []
        var i = 0
        var chunkIndex = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("<<<<<<<") {
                segments.append(joinLines(currentSegmentLines, addingTrailingNewline: true))
                currentSegmentLines = []

                let startLine = i + 1
                let block = collectBlock(lines: lines, from: i)
                guard let (parsed, consumed) = block else {
                    // Malformed — treat the marker line as plain text
                    // and move on so we don't infinite-loop.
                    currentSegmentLines.append(line)
                    i += 1
                    continue
                }
                chunkIndex += 1
                chunks.append(
                    ConflictChunk(
                        index: chunkIndex,
                        originalBlock: parsed.originalBlock,
                        startLineInOriginal: startLine,
                        oursText: parsed.ours,
                        baseText: parsed.base,
                        theirsText: parsed.theirs
                    )
                )
                i += consumed
            } else {
                currentSegmentLines.append(line)
                i += 1
            }
        }
        // Final tail — the segment after the last chunk. No trailing
        // newline added because the loop already consumed every line.
        segments.append(joinLines(currentSegmentLines, addingTrailingNewline: false))
        return (segments, chunks)
    }

    private struct ParsedBlock {
        let originalBlock: String
        let ours: String
        let base: String?
        let theirs: String
    }

    /// Scans from a `<<<<<<<` line through the matching `>>>>>>>`,
    /// returning the parsed sides and how many input lines were
    /// consumed. Returns nil if no closing marker is found.
    private static func collectBlock(lines: [String], from start: Int) -> (ParsedBlock, Int)? {
        var ours: [String] = []
        var base: [String] = []
        var theirs: [String] = []
        var section: Section = .ours
        var consumed = 0

        // The first line is the `<<<<<<<` itself.
        consumed = 1
        var i = start + 1
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("|||||||") {
                section = .base
                consumed += 1
                i += 1
                continue
            }
            if line.hasPrefix("=======") {
                section = .theirs
                consumed += 1
                i += 1
                continue
            }
            if line.hasPrefix(">>>>>>>") {
                consumed += 1
                i += 1
                // The chunk inherits whatever trailing-newline state
                // its closing `>>>>>>>` line had in the source — when
                // it's the last byte of the file (no following line),
                // the block also has no trailing newline. Without this
                // the round-trip introduces a phantom newline that
                // grows the file by one byte every save.
                let blockEndsAtFileEnd = (start + consumed) >= lines.count
                let trailing = !blockEndsAtFileEnd
                let original = joinLines(
                    Array(lines[start ..< (start + consumed)]),
                    addingTrailingNewline: trailing
                )
                return (
                    ParsedBlock(
                        originalBlock: original,
                        ours: joinLines(ours, addingTrailingNewline: trailing),
                        base: section == .base || !base.isEmpty
                            ? joinLines(base, addingTrailingNewline: trailing)
                            : nil,
                        theirs: joinLines(theirs, addingTrailingNewline: trailing)
                    ),
                    consumed
                )
            }
            switch section {
            case .ours:   ours.append(line)
            case .base:   base.append(line)
            case .theirs: theirs.append(line)
            }
            consumed += 1
            i += 1
        }
        return nil
    }

    private enum Section { case ours, base, theirs }

    /// Reassembles split lines, optionally re-adding the trailing
    /// newline that `components(separatedBy:)` strips. Empty arrays
    /// produce empty strings either way.
    private static func joinLines(_ lines: [String], addingTrailingNewline: Bool) -> String {
        if lines.isEmpty { return "" }
        let joined = lines.joined(separator: "\n")
        return addingTrailingNewline ? joined + "\n" : joined
    }
}
