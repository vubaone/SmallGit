import Foundation

/// Constructs unified-diff patch text suitable for `git apply [--cached]`.
///
/// Used to implement hunk-level (and eventually line-level) staging:
/// the user picks a hunk in the Diff panel and we synthesise a patch
/// containing just that hunk, which we then feed back to git.
enum DiffPatchBuilder {

    /// Build a multi-hunk patch for `file` containing the given hunks.
    /// Returns `nil` if `hunks` is empty.
    ///
    /// The result always ends with a trailing newline — `git apply` rejects
    /// patches that don't.
    static func buildPatch(file: String, hunks: [DiffHunk]) -> String? {
        guard !hunks.isEmpty else { return nil }
        var out = ""
        out += "diff --git a/\(file) b/\(file)\n"
        out += "--- a/\(file)\n"
        out += "+++ b/\(file)\n"
        for hunk in hunks {
            out += renderHunk(hunk)
        }
        return out
    }

    /// Convenience for the common case: stage exactly one hunk.
    static func buildPatch(file: String, hunk: DiffHunk) -> String? {
        buildPatch(file: file, hunks: [hunk])
    }

    /// Which way the patch will be handed to `git apply` — which decides how
    /// the lines the user did *not* pick get collapsed.
    ///
    /// The two directions are not symmetric, and picking the wrong one builds
    /// a patch git refuses with "patch does not apply". git matches a
    /// patch against the target by one side only: forward it matches the
    /// preimage, reverse it matches the postimage. So the untargeted lines
    /// have to be collapsed into whichever side is doing the matching, and
    /// that is the opposite side in each case.
    enum Direction: Sendable {

        /// `git apply` — the preimage is matched, so the patch must describe
        /// the diff's OLD side: staging.
        case forward

        /// `git apply --reverse` — the POSTIMAGE is matched, so the patch
        /// must describe the diff's NEW side: unstaging and discarding.
        case reverse
    }

    /// Build a patch covering **only** `targetLine` from `hunk`, for
    /// application in `direction`. See `buildLinesPatch` for how the rest of
    /// the hunk is collapsed.
    ///
    /// Identity is by `DiffLine.id` (UUID), so `targetLine` must be one of
    /// the lines in `hunk.lines`.
    static func buildLinePatch(
        file: String,
        hunk: DiffHunk,
        targetLine: DiffLine,
        direction: Direction = .forward
    ) -> String? {
        guard targetLine.type == .add || targetLine.type == .del else { return nil }
        guard hunk.lines.contains(where: { $0.id == targetLine.id }) else { return nil }
        return buildLinesPatch(
            file: file,
            hunks: [hunk],
            targetLineIDs: [targetLine.id],
            direction: direction
        )
    }

    /// Multi-hunk, multi-line generalization of `buildLinePatch`: one
    /// unified-diff patch carrying every line in `targetLineIDs` and nothing
    /// else.
    ///
    /// Lines whose id is in `targetLineIDs` are kept as-is (only the `+` /
    /// `-` types make it through) and context lines stay as context. What
    /// happens to the *other* changed lines is the whole point of
    /// `direction`, because git matches a different side of the patch each
    /// way round:
    ///
    /// - `.forward` (`git apply`) matches the **preimage**, which must be the
    ///   diff's old side. Other `-` lines are demoted to context — the old
    ///   side still holds them — and other `+` lines are dropped, since the
    ///   old side never had them.
    /// - `.reverse` (`git apply --reverse`) matches the **postimage**, which
    ///   must be the diff's new side. So it is the exact mirror: other `+`
    ///   lines are demoted to context — the new side holds them — and other
    ///   `-` lines are dropped, since the new side no longer has them.
    ///
    /// Collapsing the forward way and then reversing is what "patch does not
    /// apply" looks like: the dropped `+` lines are sitting in the target
    /// file in between the kept ones, and the demoted `-` lines are not in
    /// it at all, so the postimage matches nothing.
    ///
    /// - Exception: a no-trailing-newline line is a newline *boundary*, and
    ///   the marker git writes for it is only legal on the last line of a
    ///   hunk. Such a line is kept together with its partner rather than
    ///   collapsed — see the inline notes.
    /// - A hunk that contains no target lines after filtering is omitted
    ///   entirely — `git apply` rejects no-op hunks.
    ///
    /// Returns nil if `targetLineIDs` is empty or no hunk references any
    /// of the requested ids with an actionable type.
    static func buildLinesPatch(
        file: String,
        hunks: [DiffHunk],
        targetLineIDs: Set<UUID>,
        direction: Direction = .forward
    ) -> String? {
        guard !targetLineIDs.isEmpty else { return nil }

        var keptHunks: [DiffHunk] = []
        for hunk in hunks {
            // A line with no trailing newline is a newline *boundary*: the
            // other side re-writes that same line (now with a newline) before
            // anything can follow it. The marker git emits for one is only
            // legal on a hunk's last line, so collapsing half of such a pair
            // while keeping something after it builds a patch git can't
            // apply. Both directions have this, on opposite line types:
            // forward it is the `-` that would be demoted to context, reverse
            // it is the `+`. Pull the boundary pair into the target set so
            // they travel together.
            //
            // `boundary` is the type that would be collapsed *and* carries
            // the marker; `partner` is the type that re-writes it.
            let boundary: DiffLineType = direction == .forward ? .del : .add
            let partner:  DiffLineType = direction == .forward ? .add : .del
            var effective = targetLineIDs
            for (i, line) in hunk.lines.enumerated()
            where line.type == boundary && line.noNewlineAtEOF {
                let rest = hunk.lines[(i + 1)...]
                let hasLaterPartnerTarget = rest.contains {
                    $0.type == partner && targetLineIDs.contains($0.id)
                }
                guard hasLaterPartnerTarget else { continue }
                effective.insert(line.id)
                if let reWrite = rest.first(where: { $0.type == partner }) {
                    effective.insert(reWrite.id)
                }
            }

            let hasActionableTarget = hunk.lines.contains { line in
                effective.contains(line.id)
                    && (line.type == .add || line.type == .del)
            }
            guard hasActionableTarget else { continue }

            let collapsed = direction == .forward
                ? collapsedForward(hunk.lines, targets: effective)
                : collapsedReverse(hunk.lines, targets: effective)
            keptHunks.append(DiffHunk(
                oldStart: hunk.oldStart,
                oldCount: 0,
                newStart: hunk.newStart,
                newCount: 0,
                lines: collapsed
            ))
        }
        guard !keptHunks.isEmpty else { return nil }
        return buildPatch(file: file, hunks: keptHunks)
    }

    // MARK: - Collapsing the lines the user did not pick

    /// Demote `line` to context under `number` — the line number the matched
    /// side knows it by, which as context it occupies in both columns.
    private static func asContext(_ line: DiffLine, numberedBy number: Int?) -> DiffLine {
        DiffLine(
            type: .context,
            content: line.content,
            oldLineNumber: number,
            newLineNumber: number,
            noNewlineAtEOF: line.noNewlineAtEOF
        )
    }

    /// Collapse for `git apply`: the preimage is matched, so what survives
    /// has to spell out the diff's OLD side. Untargeted `-` lines are still
    /// in it and become context; untargeted `+` lines were never in it and
    /// go. Hunk order is already old-side order, so one pass does it.
    private static func collapsedForward(
        _ lines: [DiffLine],
        targets: Set<UUID>
    ) -> [DiffLine] {
        var out: [DiffLine] = []
        for line in lines {
            if targets.contains(line.id), line.type == .add || line.type == .del {
                out.append(line)
                continue
            }
            switch line.type {
            case .context:
                out.append(line)
            case .del:
                out.append(asContext(line, numberedBy: line.oldLineNumber))
            case .add, .empty:
                continue
            }
        }
        return out
    }

    /// Collapse for `git apply --reverse`: the POSTIMAGE is matched, so what
    /// survives has to spell out the diff's NEW side — untargeted `+` lines
    /// become context, untargeted `-` lines go.
    ///
    /// Order is the other half of that, and it is why this can't be one pass
    /// like the forward case. A hunk lists every `-` of a run before every
    /// `+`, which is old-side order; emitting a restored `-` there drops it
    /// at the top of the run instead of where the line it replaces sits. So
    /// each run is re-paired the way `DiffPairing` pairs it for the
    /// side-by-side view — k-th deletion against k-th addition — and emitted
    /// pairwise, which is new-side order with each restored line beside the
    /// one it is taking the place of.
    private static func collapsedReverse(
        _ lines: [DiffLine],
        targets: Set<UUID>
    ) -> [DiffLine] {
        var out: [DiffLine] = []
        var i = 0
        while i < lines.count {
            switch lines[i].type {
            case .context:
                out.append(lines[i])
                i += 1
            case .empty:
                i += 1
            case .del, .add:
                var dels: [DiffLine] = []
                var adds: [DiffLine] = []
                while i < lines.count, lines[i].type == .del { dels.append(lines[i]); i += 1 }
                while i < lines.count, lines[i].type == .add { adds.append(lines[i]); i += 1 }
                for k in 0..<max(dels.count, adds.count) {
                    // The deletion first: it is being put back *above* the
                    // line that replaced it, which is where it was.
                    if k < dels.count, targets.contains(dels[k].id) {
                        out.append(dels[k])
                    }
                    guard k < adds.count else { continue }
                    let add = adds[k]
                    out.append(
                        targets.contains(add.id)
                            ? add
                            : asContext(add, numberedBy: add.newLineNumber)
                    )
                }
            }
        }
        return out
    }

    // MARK: - Internal

    /// Render a single hunk in unified-diff format. We recompute the line
    /// counts from the hunk body so the header is always self-consistent —
    /// some upstream parsers (or our own future trimming) may have produced
    /// a header that no longer matches.
    private static func renderHunk(_ hunk: DiffHunk) -> String {
        var oldCount = 0
        var newCount = 0
        for line in hunk.lines {
            switch line.type {
            case .context: oldCount += 1; newCount += 1
            case .del:     oldCount += 1
            case .add:                    newCount += 1
            case .empty:   continue
            }
        }
        var out = "@@ -\(hunk.oldStart),\(oldCount) +\(hunk.newStart),\(newCount) @@\n"
        for line in hunk.lines {
            switch line.type {
            case .context: out += " "  + line.content + "\n"
            case .del:     out += "-"  + line.content + "\n"
            case .add:     out += "+"  + line.content + "\n"
            case .empty:   continue
            }
            // Reproduce git's no-trailing-newline marker so the patch matches
            // the on-disk / indexed content exactly.
            if line.noNewlineAtEOF {
                out += "\\ No newline at end of file\n"
            }
        }
        return out
    }
}
