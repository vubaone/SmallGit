import Foundation
import Observation

/// Drives the 4-pane conflict resolver: pulls the three blob stages
/// out of the index (base / ours / theirs) plus the working-tree
/// contents the user is editing, parses the conflict chunks, and
/// exposes per-chunk + file-level resolution actions.
///
/// Pane semantics, Beyond-Compare style:
///   - Ours    : current branch's version of the file (stage 2)
///   - Base    : common ancestor (stage 1) — missing for add/add
///   - Theirs  : incoming branch's version (stage 3)
///   - Merged  : working-tree contents with conflict markers — initially
///               from git's merge attempt, edited as chunks are resolved
@MainActor
@Observable
final class ConflictResolutionViewModel {

    var path: String?
    var oursText: String = ""
    var theirsText: String = ""
    var baseText: String = ""
    var mergedText: String = ""
    var hasBase: Bool = false
    /// Which kind of conflict this is, worked out from the stages that
    /// actually came back. A modify/delete has nothing to show in the
    /// pane the deleting side would have filled, and no markers in the
    /// merged buffer either — the window has to say so rather than open
    /// on four empty panes.
    var conflictKind: ConflictKind?
    var isLoading: Bool = false
    var errorMessage: String?

    /// Conflict chunks parsed from the *initial* working-tree contents.
    /// Each chunk records its own resolution choice so the chunk list
    /// can show "X of N resolved". Manual edits to `mergedText` don't
    /// remove entries here — they stay as reference cards even after
    /// the marker block has been replaced.
    var chunks: [ConflictChunk] = []
    var resolutions: [UUID: ConflictChunk.Resolution] = [:]

    /// Text *between* chunks in the original working-tree file —
    /// `segments[i]` precedes `chunks[i]`, and `segments[chunks.count]`
    /// is the tail after the last chunk. Captured at parse time so
    /// `rebuildMergedText` can produce a deterministic merged buffer
    /// no matter what order chunk decisions arrive in. Search-and-
    /// replace on the live text breaks the moment any chunk goes
    /// `.neither` (no anchor left) — a full rebuild side-steps that.
    private var segments: [String] = []

    /// Currently-focused chunk for Prev/Next navigation. Drives the
    /// merged editor's auto-scroll and the chunk inspector highlight.
    var focusedChunkID: UUID?

    private let git: GitService
    private let coordinator: CacheCoordinator

    init(git: GitService = .shared, coordinator: CacheCoordinator) {
        self.git = git
        self.coordinator = coordinator
    }

    /// Pull the three index stages + the working-tree text for `path`.
    /// All four reads happen in parallel; if any single read fails the
    /// resolver still opens — the failed pane just shows empty.
    func load(path: String) async {
        self.path = path
        self.isLoading = true
        self.errorMessage = nil
        defer { isLoading = false }

        guard let repo = coordinator.activeRepoPath else {
            errorMessage = "No active repository"
            return
        }

        async let oursTask   = try? await git.conflictVersion(repoPath: repo, path: path, side: .ours)
        async let theirsTask = try? await git.conflictVersion(repoPath: repo, path: path, side: .theirs)
        async let baseTask   = try? await git.conflictVersion(repoPath: repo, path: path, side: .base)

        let oursVal   = await oursTask ?? nil
        let theirsVal = await theirsTask ?? nil
        let baseVal   = await baseTask ?? nil

        self.oursText   = oursVal ?? ""
        self.theirsText = theirsVal ?? ""
        self.baseText   = baseVal ?? ""
        self.hasBase    = (baseVal != nil)
        self.conflictKind = ConflictKind(
            hasBase: baseVal != nil,
            hasOurs: oursVal != nil,
            hasTheirs: theirsVal != nil
        )
        self.mergedText = readWorkingTree(repo: repo, path: path) ?? ""
        // Snapshot of the file as git left it, so "has the user actually
        // changed anything?" is answerable without guessing. Both the chunk
        // buttons and hand edits to the merged pane flow into `mergedText`,
        // so one comparison covers both.
        self.loadedMergedText = self.mergedText

        let parsed = ConflictParser.parse(mergedText)
        self.chunks = parsed.chunks
        self.segments = parsed.segments
        self.resolutions = Dictionary(
            uniqueKeysWithValues: parsed.chunks.map { ($0.id, .unresolved) }
        )
        self.focusedChunkID = parsed.chunks.first?.id
    }

    /// The merged buffer as loaded from disk, before any resolution.
    private(set) var loadedMergedText: String = ""

    /// Seam for tests, which build a view model without a real repository to
    /// load from. Not used by the app.
    func loadForTesting(_ text: String) {
        mergedText = text
        loadedMergedText = text
        let parsed = ConflictParser.parse(text)
        chunks = parsed.chunks
        segments = parsed.segments
        resolutions = Dictionary(uniqueKeysWithValues: parsed.chunks.map { ($0.id, .unresolved) })
        focusedChunkID = parsed.chunks.first?.id
    }

    /// Whether leaving now would throw work away.
    ///
    /// Nothing in this window touches disk until Save & Stage, so closing is
    /// always safe for the repository — this is only about not silently
    /// discarding the user's own decisions.
    var hasUnsavedWork: Bool {
        mergedText != loadedMergedText
    }

    private func readWorkingTree(repo: String, path: String) -> String? {
        let url = URL(fileURLWithPath: repo).appendingPathComponent(path)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Highlight ranges (for the read-only panes)

    /// Inclusive 1-based line range to paint with the conflict color
    /// in one of the read-only panes. Carries the originating chunk
    /// ID so the focused-chunk shade can be selected at render time,
    /// plus `trailingPadding` — extra empty rows the pane should
    /// render after `endLine` so this side's conflict block matches
    /// the height of the tallest side's conflict block. That's what
    /// keeps the post-conflict context aligned across Ours / Base /
    /// Theirs, the way Beyond Compare does.
    struct HighlightRange: Hashable {
        let startLine: Int
        let endLine: Int
        let chunkID: UUID
        let trailingPadding: Int
    }

    /// Lines in the Ours blob that map back to each chunk's ours-side
    /// content. The block git inserts between `<<<<<<<` and `=======`
    /// is verbatim from the ours blob, so a literal substring search
    /// is enough to recover the line range — no diff necessary.
    var oursHighlights: [HighlightRange] {
        computeHighlights(in: oursText) { $0.oursText }
    }

    var theirsHighlights: [HighlightRange] {
        computeHighlights(in: theirsText) { $0.theirsText }
    }

    var baseHighlights: [HighlightRange] {
        guard hasBase else { return [] }
        return computeHighlights(in: baseText) { $0.baseText ?? "" }
    }

    /// Sides whose blob does not exist at all, because the branch on
    /// that side deleted the file. Their pane renders empty, and it has
    /// to say why — an empty column otherwise reads as a failed load.
    var deletedSides: Set<ConflictLineSide> {
        guard let kind = conflictKind, kind.isDeleteConflict else { return [] }
        var sides: Set<ConflictLineSide> = []
        if !kind.hasOurs { sides.insert(.ours) }
        if !kind.hasTheirs { sides.insert(.theirs) }
        return sides
    }

    private func computeHighlights(
        in fullText: String,
        sideText: (ConflictChunk) -> String
    ) -> [HighlightRange] {
        var ranges: [HighlightRange] = []
        for chunk in chunks {
            let needle = sideText(chunk)
            if needle.isEmpty { continue }
            let trimmedNeedle = needle.hasSuffix("\n")
                ? String(needle.dropLast())
                : needle
            // Pad this side's block to the tallest side's height so
            // the conflict region renders at the same row count
            // across panes — the alignment Beyond Compare gives you
            // for free with its 3-way diff layout.
            let thisCount   = lineCount(needle)
            let oursCount   = lineCount(chunk.oursText)
            let baseCount   = chunk.baseText.map(lineCount) ?? 0
            let theirsCount = lineCount(chunk.theirsText)
            let target = max(oursCount, max(baseCount, theirsCount))
            let padding = max(0, target - thisCount)

            if let r = Self.lineRange(
                of: trimmedNeedle,
                in: fullText,
                chunkID: chunk.id,
                trailingPadding: padding
            ) {
                ranges.append(r)
            }
        }
        return ranges
    }

    private func lineCount(_ text: String) -> Int {
        if text.isEmpty { return 0 }
        // A trailing newline shouldn't count as an extra blank line —
        // `"a\n"` is one line, not two. `components(separatedBy:)`
        // would give us 2 elements; the count below treats it as 1.
        let stripped = text.hasSuffix("\n") ? String(text.dropLast()) : text
        return stripped.reduce(into: 1) { $0 += $1 == "\n" ? 1 : 0 }
    }

    private static func lineRange(
        of needle: String,
        in haystack: String,
        chunkID: UUID,
        trailingPadding: Int
    ) -> HighlightRange? {
        guard let range = haystack.range(of: needle) else { return nil }
        let startLine = haystack[..<range.lowerBound]
            .reduce(into: 0) { $0 += $1 == "\n" ? 1 : 0 } + 1
        let needleNewlines = needle.reduce(into: 0) { $0 += $1 == "\n" ? 1 : 0 }
        let endLine = startLine + needleNewlines
        return HighlightRange(
            startLine: startLine,
            endLine: endLine,
            chunkID: chunkID,
            trailingPadding: trailingPadding
        )
    }

    // MARK: - Chunk-level resolution

    /// Number of chunks with a non-`.unresolved` choice. Since
    /// `rebuildMergedText` is the only writer of `mergedText` for
    /// chunk decisions, the resolution dictionary is now the source
    /// of truth — no need to cross-check the live buffer.
    var resolvedCount: Int {
        chunks.filter { (resolutions[$0.id] ?? .unresolved) != .unresolved }.count
    }

    var unresolvedChunks: [ConflictChunk] {
        chunks.filter { (resolutions[$0.id] ?? .unresolved) == .unresolved }
    }

    var allChunksResolved: Bool {
        chunks.allSatisfy { (resolutions[$0.id] ?? .unresolved) != .unresolved }
    }

    /// Record the user's pick for `chunk` and rebuild the merged
    /// buffer from segments + current resolutions. Always produces
    /// the right answer regardless of click order or which
    /// resolutions empty the slot — re-clicking Ours after Neither
    /// works the same as the first click.
    ///
    /// Trade-off: any free-form edits the user made in the merged
    /// pane are overwritten by the rebuild. The intended workflow is
    /// "pick chunks first, then polish manually" — the Save & Stage
    /// button is where manual edits land.
    func resolve(chunk: ConflictChunk, to resolution: ConflictChunk.Resolution) {
        resolutions[chunk.id] = resolution
        rebuildMergedText()
        // In-memory until Save & Stage, so nothing else in the log records
        // it — which made "what did I actually click before it went wrong?"
        // unanswerable after the fact.
        Log.app("conflict.chunk", detail: "\(path ?? "") chunk \(chunk.index) → \(resolution)")
    }

    /// Bulk version of `resolve` — applies one resolution to every
    /// chunk and rebuilds the buffer once at the end so we don't pay
    /// the rebuild cost N times.
    func resolveAll(to resolution: ConflictChunk.Resolution) {
        for c in chunks { resolutions[c.id] = resolution }
        rebuildMergedText()
        Log.app("conflict.bulk", detail: "\(path ?? "") \(chunks.count) chunks → \(resolution)")
    }

    /// Assemble the merged buffer from `segments` interleaved with
    /// each chunk's resolved text. Pure function over state — the
    /// only writer of `mergedText` apart from the TextEditor binding
    /// and the post-load working-tree read.
    private func rebuildMergedText() {
        mergedText = composedText()
    }

    /// The buffer the current resolutions describe. `mergedText` starts life
    /// as this and drifts from it the moment the user types in the merged
    /// pane — which is allowed, and is why the line inspector compares the
    /// two rather than trusting either alone.
    private func composedText() -> String {
        var out = ""
        for (i, segment) in segments.enumerated() {
            out += segment
            if i < chunks.count {
                let c = chunks[i]
                out += c.resolvedText(resolutions[c.id] ?? .unresolved)
            }
        }
        return out
    }

    func resolution(for chunk: ConflictChunk) -> ConflictChunk.Resolution {
        resolutions[chunk.id] ?? .unresolved
    }

    // MARK: - What one row becomes

    /// What the merged file holds at `row` — the line inspector's FINAL line.
    ///
    /// Read out of the live buffer rather than deduced from the button that
    /// was pressed, because the merged pane is editable and the two part
    /// company the moment someone types in it. A chunk's answer and the
    /// file's answer are then different things, and the one worth showing is
    /// the file's.
    func outcome(forRow row: ConflictLineRow, chunkID: UUID?) -> ConflictRowOutcome {
        guard let chunkID, let chunk = chunks.first(where: { $0.id == chunkID }) else {
            return ConflictRowOutcome.compute(row: row, chunkID: nil, resolution: .unresolved)
        }
        let chosen = ConflictRowOutcome.compute(
            row: row, chunkID: chunkID, resolution: resolution(for: chunk)
        )
        // Undecided, deleted, or contributing nothing: there is no line in
        // the file to go and read, so the chunk's own answer is the answer.
        guard case .resolved(let lines) = chosen, !lines.isEmpty else { return chosen }
        guard let live = liveLines(forRow: row, chunk: chunk) else { return .unmappable }
        return live == lines ? .resolved(live) : .edited(live)
    }

    /// The lines `row` occupies in the live merged buffer, or nil when hand
    /// edits have moved them.
    ///
    /// Line *numbers* only shift when lines are added or removed, so an edit
    /// inside a line — the common polish — still lines up and is worth
    /// showing. A changed line count means every index past it is a guess,
    /// and a guess is worse here than saying so.
    private func liveLines(forRow row: ConflictLineRow, chunk: ConflictChunk) -> [String]? {
        let merged = mergedText.components(separatedBy: "\n")
        guard merged.count == composedText().components(separatedBy: "\n").count else { return nil }
        guard let start = composedStartLine(ofChunk: chunk.id) else { return nil }
        guard let indices = composedIndices(forRow: row, chunk: chunk, start: start) else { return nil }
        guard indices.allSatisfy({ merged.indices.contains($0) }) else { return nil }
        return indices.map { merged[$0] }
    }

    /// 0-based line where a chunk's resolved text begins in the composed
    /// buffer — walked the same way the buffer is built, so the two cannot
    /// disagree about where a chunk starts.
    private func composedStartLine(ofChunk id: UUID) -> Int? {
        var line = 0
        for (i, segment) in segments.enumerated() {
            line += segment.reduce(into: 0) { $0 += $1 == "\n" ? 1 : 0 }
            guard i < chunks.count else { break }
            let chunk = chunks[i]
            if chunk.id == id { return line }
            line += chunk
                .resolvedText(resolutions[chunk.id] ?? .unresolved)
                .reduce(into: 0) { $0 += $1 == "\n" ? 1 : 0 }
        }
        return nil
    }

    /// Where this row's contribution sits inside the chunk's block — one
    /// index for a single side, two when both sides were kept and the row
    /// has a line on each.
    private func composedIndices(
        forRow row: ConflictLineRow,
        chunk: ConflictChunk,
        start: Int
    ) -> [Int]? {
        func offset(_ side: ConflictLineSide) -> Int? {
            guard let cell = row.cell(for: side) else { return nil }
            let ranges: [HighlightRange]
            switch side {
            case .ours:   ranges = oursHighlights
            case .base:   ranges = baseHighlights
            case .theirs: ranges = theirsHighlights
            }
            guard let range = ranges.first(where: { $0.chunkID == chunk.id }) else { return nil }
            let offset = cell.lineNumber - range.startLine
            // Inside the chunk's own block or nowhere: a row that sits past
            // the end of it belongs to another part of the file, and an
            // offset from the wrong anchor would point somewhere plausible
            // and wrong.
            guard offset >= 0, offset <= range.endLine - range.startLine else { return nil }
            return offset
        }
        func single(_ side: ConflictLineSide) -> [Int]? {
            offset(side).map { [start + $0] }
        }
        switch resolution(for: chunk) {
        case .ours:   return single(.ours)
        case .base:   return single(.base)
        case .theirs: return single(.theirs)
        case .bothOursFirst:
            let first = offset(.ours).map { start + $0 }
            let second = offset(.theirs).map { start + lineCount(chunk.oursText) + $0 }
            let both = [first, second].compactMap { $0 }
            return both.isEmpty ? nil : both
        case .bothTheirsFirst:
            let first = offset(.theirs).map { start + $0 }
            let second = offset(.ours).map { start + lineCount(chunk.theirsText) + $0 }
            let both = [first, second].compactMap { $0 }
            return both.isEmpty ? nil : both
        case .unresolved, .neither:
            return nil
        }
    }

    // MARK: - Navigation

    func focusNext() {
        guard !chunks.isEmpty else { return }
        guard let current = focusedChunkID,
              let idx = chunks.firstIndex(where: { $0.id == current }) else {
            focusedChunkID = chunks.first?.id
            return
        }
        focusedChunkID = chunks[(idx + 1) % chunks.count].id
    }

    func focusPrevious() {
        guard !chunks.isEmpty else { return }
        guard let current = focusedChunkID,
              let idx = chunks.firstIndex(where: { $0.id == current }) else {
            focusedChunkID = chunks.last?.id
            return
        }
        focusedChunkID = chunks[(idx - 1 + chunks.count) % chunks.count].id
    }

    func focusNextUnresolved() {
        guard !chunks.isEmpty else { return }
        let unresolved = unresolvedChunks
        guard !unresolved.isEmpty else { return }
        // Pick the first unresolved chunk strictly after the current
        // focus — wraps around to the top if there isn't one.
        if let current = focusedChunkID,
           let idx = chunks.firstIndex(where: { $0.id == current }) {
            let after = chunks[(idx + 1)...]
            if let next = after.first(where: { resolution(for: $0) == .unresolved }) {
                focusedChunkID = next.id
                return
            }
        }
        focusedChunkID = unresolved.first?.id
    }

    // MARK: - Resolution actions

    func acceptOurs() async -> Bool {
        guard let repo = coordinator.activeRepoPath, let path else { return false }
        do {
            _ = try await git.acceptOurs(repoPath: repo, path: path)
            coordinator.after(.stage(files: [path]))
            Log.app("conflict.takeOursFile", detail: path)
            return true
        } catch {
            Log.app("conflict.takeOursFile.failed", detail: "\(path): \(error)")
            errorMessage = "Accept ours failed: \(error.localizedDescription)"
            return false
        }
    }

    func acceptTheirs() async -> Bool {
        guard let repo = coordinator.activeRepoPath, let path else { return false }
        do {
            _ = try await git.acceptTheirs(repoPath: repo, path: path)
            coordinator.after(.stage(files: [path]))
            Log.app("conflict.takeTheirsFile", detail: path)
            return true
        } catch {
            Log.app("conflict.takeTheirsFile.failed", detail: "\(path): \(error)")
            errorMessage = "Accept theirs failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Writes the user-edited merged text to the working tree and
    /// stages it as the resolution. Caller is responsible for
    /// confirming any remaining conflict markers were intentional —
    /// git would happily commit `<<<<<<<` lines if we let it.
    func saveAndMarkResolved() async -> Bool {
        guard let repo = coordinator.activeRepoPath, let path else { return false }
        let url = URL(fileURLWithPath: repo).appendingPathComponent(path)
        do {
            try mergedText.write(to: url, atomically: true, encoding: .utf8)
            _ = try await git.markResolved(repoPath: repo, path: path)
            coordinator.after(.stage(files: [path]))
            Log.app("conflict.staged", detail: "\(path) · \(mergedText.utf8.count) bytes")
            return true
        } catch {
            Log.app("conflict.staged.failed", detail: "\(path): \(error)")
            errorMessage = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Rewrites this file's conflict markers to include the common ancestor,
    /// then reloads so the chunks carry a base to take.
    ///
    /// Rebuilds the file from the index, so it throws away anything the user
    /// has done to it — the caller confirms before getting here.
    func loadAncestorSections() async -> Bool {
        guard let repo = coordinator.activeRepoPath, let path else { return false }
        do {
            let result = try await git.restoreConflictMarkersWithAncestor(repoPath: repo, path: path)
            guard result.succeeded else {
                errorMessage = "Could not add ancestor sections: \(result.combinedOutput)"
                Log.app("conflict.ancestors.failed", detail: "\(path): \(result.combinedOutput)")
                return false
            }
            await load(path: path)
            Log.app("conflict.ancestors", detail: "\(path) · base available: \(hasPerChunkBase)")
            return hasPerChunkBase
        } catch {
            errorMessage = "Could not add ancestor sections: \(error.localizedDescription)"
            Log.app("conflict.ancestors.failed", detail: "\(path): \(error)")
            return false
        }
    }

    /// Whether any chunk carries a base section, i.e. whether "take the
    /// common ancestor" is offerable at all.
    ///
    /// git's default `merge.conflictStyle` writes only ours and theirs into
    /// the markers, so the ancestor simply isn't in the file. `diff3` and
    /// `zdiff3` add a `|||||||` section and this becomes true. The whole-file
    /// BASE pane above comes from stage 1 of the index instead, which is why
    /// it can be shown even when individual chunks have no base to take.
    var hasPerChunkBase: Bool {
        chunks.contains { $0.baseText != nil }
    }

    /// `true` if the user's merged-pane text still contains git's
    /// conflict markers. Used to gate the save action with a warning.
    var mergedStillHasMarkers: Bool {
        let lines = mergedText.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.contains { line in
            line.hasPrefix("<<<<<<<") || line.hasPrefix("=======") || line.hasPrefix(">>>>>>>")
        }
    }
}
