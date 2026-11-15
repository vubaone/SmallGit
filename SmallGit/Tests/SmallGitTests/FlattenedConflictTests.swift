import XCTest
@testable import SmallGit

/// The conflict git stops calling a conflict.
///
/// `git reset` on an unmerged path does not unstage anything — there was
/// nothing staged. It collapses the three merge stages into one entry matching
/// HEAD and leaves the working tree exactly as it was, markers and all. What
/// the user is left with looks like an ordinary modification: no Conflict
/// state, no resolver, a banner reading "all conflicts resolved", and a
/// Continue button git refuses over the unstaged change while telling them to
/// go resolve a conflict nothing on screen shows.
///
/// SmallGit's own Unstage produced that state until the guard below; a
/// terminal still can. So these cover both halves: not making it, and getting
/// out of it once it exists.
final class FlattenedConflictTests: XCTestCase {

    private struct Sandbox {
        let runner: ProcessRunner
        let git: GitService
        let repo: String
        let root: URL
    }

    private func makeSandbox() async throws -> Sandbox {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-flattened-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = root.appendingPathComponent("repo").path
        _ = try await runner.run(in: root.path, args: ["init", "-q", "-b", "main", "repo"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name", "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])
        return Sandbox(runner: runner, git: GitService(runner: runner), repo: repo, root: root)
    }

    private func write(_ box: Sandbox, _ name: String, _ body: String) throws {
        try body.write(
            to: URL(fileURLWithPath: box.repo).appendingPathComponent(name),
            atomically: true, encoding: .utf8
        )
    }

    private func read(_ box: Sandbox, _ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: box.repo).appendingPathComponent(name),
                   encoding: .utf8)
    }

    /// A rebase paused on a conflict in `a.txt`, with `keep.txt` committed
    /// clean alongside it so "unrelated file" has something to mean.
    private func pausedRebase() async throws -> Sandbox {
        let box = try await makeSandbox()
        try write(box, "a.txt", "base\n")
        try write(box, "keep.txt", "untouched\n")
        _ = try await box.runner.run(in: box.repo, args: ["add", "-A"])
        _ = try await box.runner.run(in: box.repo, args: ["commit", "-qm", "base"])

        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "-b", "feature"])
        try write(box, "a.txt", "theirs\n")
        _ = try await box.runner.run(in: box.repo, args: ["commit", "-qam", "feature"])

        _ = try await box.runner.run(in: box.repo, args: ["checkout", "-q", "main"])
        try write(box, "a.txt", "ours\n")
        _ = try await box.runner.run(in: box.repo, args: ["commit", "-qam", "main"])

        _ = try await box.runner.run(in: box.repo, args: ["rebase", "feature"])
        let op = await box.git.inProgressOperation(repoPath: box.repo)
        XCTAssertEqual(op, .rebase, "the rebase should be paused on a conflict")
        return box
    }

    // MARK: - What git actually does, which is the reason for all of this

    func testResettingAConflictedPathHidesTheConflictWithoutFixingTheFile() async throws {
        let box = try await pausedRebase()
        defer { try? FileManager.default.removeItem(at: box.root) }

        _ = try await box.git.unstage(repoPath: box.repo, files: ["a.txt"])

        let status = try await box.git.status(repoPath: box.repo)
        let row = try XCTUnwrap(status.first { $0.path == "a.txt" })
        XCTAssertFalse(row.isConflict, "git has stopped calling it a conflict…")
        XCTAssertEqual(row.stateDisplay, "Modified", "…and the panel would show it as ordinary work")
        XCTAssertTrue(
            try read(box, "a.txt").contains("<<<<<<< "),
            "while the file still holds the markers nobody resolved"
        )

        // And the Continue the banner offers cannot run: the sequencer stops
        // at the unstaged change, blaming a conflict that is no longer listed.
        let result = try await box.git.continueOperation(repoPath: box.repo, operation: .rebase)
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(
            result.combinedOutput.contains("You must edit all merge conflicts"),
            "got: \(result.combinedOutput)"
        )
    }

    // MARK: - Not making it

    @MainActor
    func testUnstageLeavesAConflictAlone() async throws {
        let box = try await pausedRebase()
        defer { try? FileManager.default.removeItem(at: box.root) }

        let app = makeIsolatedAppState(git: box.git)
        app.activeRepo = RepositoryEntry(path: box.repo, name: "repo")
        app.coordinator.switchRepo(to: box.repo)
        app.filesVM.files = try await box.git.status(repoPath: box.repo)

        await app.unstage(files: ["a.txt"])

        let status = try await box.git.status(repoPath: box.repo)
        XCTAssertTrue(
            status.contains { $0.path == "a.txt" && $0.isConflict },
            "the conflict must survive an Unstage aimed at it"
        )
        XCTAssertEqual(app.statusText, "Nothing to unstage — the file is conflicted")
    }

    @MainActor
    func testUnstageStillTakesBackEverythingElseInTheSelection() async throws {
        let box = try await pausedRebase()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try write(box, "keep.txt", "edited during the rebase\n")
        _ = try await box.runner.run(in: box.repo, args: ["add", "keep.txt"])

        let app = makeIsolatedAppState(git: box.git)
        app.activeRepo = RepositoryEntry(path: box.repo, name: "repo")
        app.coordinator.switchRepo(to: box.repo)
        app.filesVM.files = try await box.git.status(repoPath: box.repo)

        await app.unstage(files: ["a.txt", "keep.txt"])

        let status = try await box.git.status(repoPath: box.repo)
        XCTAssertTrue(status.contains { $0.path == "a.txt" && $0.isConflict },
                      "the conflict is skipped, not the whole command")
        let keep = try XCTUnwrap(status.first { $0.path == "keep.txt" })
        XCTAssertFalse(keep.isStaged, "the file that really was staged comes back out")
    }

    /// The Files panel's own answer for what Unstage may touch, which is what
    /// greys the menu item out when a conflict is all that is selected.
    @MainActor
    func testSelectionDropsConflictsFromItsUnstageTargets() {
        let files = FilesViewModel(coordinator: CacheCoordinator())
        files.files = [
            GitFileStatus(path: "a.txt", indexStatus: "U", workTreeStatus: "U", isConflict: true),
            GitFileStatus(path: "keep.txt", indexStatus: "M", workTreeStatus: "."),
        ]
        files.selectedFileIDs = ["a.txt", "keep.txt"]
        XCTAssertEqual(files.selectedUnstageablePaths, ["keep.txt"])

        files.selectedFileIDs = ["a.txt"]
        XCTAssertTrue(files.selectedUnstageablePaths.isEmpty)
    }

    // MARK: - Getting out of it

    func testRestoreConflictBringsBackBothSides() async throws {
        let box = try await pausedRebase()
        defer { try? FileManager.default.removeItem(at: box.root) }
        _ = try await box.git.unstage(repoPath: box.repo, files: ["a.txt"])

        _ = try await box.git.restoreConflict(repoPath: box.repo, files: ["a.txt"])

        let status = try await box.git.status(repoPath: box.repo)
        let row = try XCTUnwrap(status.first { $0.path == "a.txt" })
        XCTAssertTrue(row.isConflict, "the unmerged stages are back")
        XCTAssertEqual(row.conflictKind, .bothModified)

        let onDisk = try read(box, "a.txt")
        XCTAssertTrue(onDisk.contains("ours"), "got: \(onDisk)")
        XCTAssertTrue(onDisk.contains("theirs"), "got: \(onDisk)")
    }

    /// Resolving a restored conflict finishes the rebase, which is the whole
    /// point of restoring it.
    func testARestoredConflictCanBeResolvedAndContinued() async throws {
        let box = try await pausedRebase()
        defer { try? FileManager.default.removeItem(at: box.root) }
        _ = try await box.git.unstage(repoPath: box.repo, files: ["a.txt"])
        _ = try await box.git.restoreConflict(repoPath: box.repo, files: ["a.txt"])

        _ = try await box.git.acceptOurs(repoPath: box.repo, path: "a.txt")
        let result = try await box.git.continueOperation(repoPath: box.repo, operation: .rebase)

        XCTAssertTrue(result.succeeded, "got: \(result.combinedOutput)")
        let op = await box.git.inProgressOperation(repoPath: box.repo)
        XCTAssertNil(op)
    }

    @MainActor
    func testTheProbeFindsTheFlattenedConflictAndOnlyThat() async throws {
        let box = try await pausedRebase()
        defer { try? FileManager.default.removeItem(at: box.root) }
        _ = try await box.git.unstage(repoPath: box.repo, files: ["a.txt"])
        // An unrelated edit: unstaged and tracked like the flattened conflict,
        // but with no markers in it.
        try write(box, "keep.txt", "edited during the rebase\n")

        let app = makeIsolatedAppState(git: box.git)
        app.activeRepo = RepositoryEntry(path: box.repo, name: "repo")
        app.coordinator.switchRepo(to: box.repo)
        await app.refreshInProgressOperation()
        app.filesVM.files = try await box.git.status(repoPath: box.repo)

        await app.probeFlattenedConflicts()

        XCTAssertEqual(app.flattenedConflictPaths, ["a.txt"])
    }

    /// Nothing to probe once the rebase is over: no Continue to block, and no
    /// heads left for `checkout -m` to rebuild the merge from.
    @MainActor
    func testTheProbeStaysQuietWithNoOperationInFlight() async throws {
        let box = try await pausedRebase()
        defer { try? FileManager.default.removeItem(at: box.root) }
        _ = try await box.git.unstage(repoPath: box.repo, files: ["a.txt"])
        let files = try await box.git.status(repoPath: box.repo)
        _ = try await box.git.abortOperation(repoPath: box.repo, operation: .rebase)

        let app = makeIsolatedAppState(git: box.git)
        app.activeRepo = RepositoryEntry(path: box.repo, name: "repo")
        app.coordinator.switchRepo(to: box.repo)
        await app.refreshInProgressOperation()
        app.filesVM.files = files

        await app.probeFlattenedConflicts()

        XCTAssertTrue(app.flattenedConflictPaths.isEmpty)
    }

    // MARK: - Recognising a conflict block

    func testACompleteBlockIsRecognised() {
        XCTAssertTrue(AppState.holdsConflictBlock("""
        before
        <<<<<<< HEAD
        ours
        =======
        theirs
        >>>>>>> feature
        after
        """))
    }

    /// A file checked out with CRLF endings carries the `\r` into the markers,
    /// and the separator is the one line matched whole.
    func testCRLFMarkersAreRecognised() {
        let crlf = "before\r\n<<<<<<< HEAD\r\nours\r\n=======\r\ntheirs\r\n>>>>>>> feature\r\n"
        XCTAssertTrue(AppState.holdsConflictBlock(crlf))
    }

    /// `merge.conflictStyle = diff3` adds an ancestor section between the
    /// first two markers.
    func testADiff3BlockIsRecognised() {
        XCTAssertTrue(AppState.holdsConflictBlock("""
        <<<<<<< ours
        ours
        ||||||| base
        base
        =======
        theirs
        >>>>>>> theirs
        """))
    }

    /// Stricter than the prompt that warns before staging, deliberately: this
    /// answer disables a button, so a source file that merely talks about
    /// markers must not read as an unresolved merge.
    func testPartialOrIndentedMarkersAreNotAConflict() {
        XCTAssertFalse(AppState.holdsConflictBlock("<<<<<<< HEAD\nours\n"),
                       "an opening marker alone")
        XCTAssertFalse(AppState.holdsConflictBlock("=======\n>>>>>>> x\n<<<<<<< y\n"),
                       "the markers out of order")
        XCTAssertFalse(AppState.holdsConflictBlock("""
        if line.hasPrefix("<<<<<<< ") {
            // then =======
        } else if line.hasPrefix(">>>>>>> ") {
        """), "markers quoted inside code, none of them at the start of a line")
        XCTAssertFalse(AppState.holdsConflictBlock("<<<<<<<<<<<<<<<< a banner\n=======\n"),
                       "a decorative rule is not a marker")
    }

    // MARK: - What the banner says and lets you press

    func testContinueIsRefusedWhileFilesAreStillConflicted() {
        let files = [
            GitFileStatus(path: "a.txt", indexStatus: "U", workTreeStatus: "U", isConflict: true)
        ]
        XCTAssertEqual(
            InProgressOperationBanner.detail(operation: .rebase, files: files, flattenedConflictCount: 0),
            "· 1 file still conflicted"
        )
        XCTAssertNotNil(InProgressOperationBanner.continueBlocker(
            operation: .rebase, files: files, flattenedConflictCount: 0
        ))
    }

    /// The case from the bug report: git lists an ordinary modification, so
    /// the old banner said the conflicts were all resolved and offered a
    /// Continue that could not run.
    func testAFlattenedConflictIsNamedRatherThanCalledResolved() {
        let files = [GitFileStatus(path: "a.txt", indexStatus: ".", workTreeStatus: "M")]
        XCTAssertEqual(
            InProgressOperationBanner.detail(operation: .rebase, files: files, flattenedConflictCount: 1),
            "· 1 file still holds conflict markers"
        )
        XCTAssertEqual(
            InProgressOperationBanner.continueBlocker(
                operation: .rebase, files: files, flattenedConflictCount: 1
            ),
            "These files still contain conflict markers. Restore the conflict, then resolve it."
        )
    }

    /// Even an unrelated unstaged edit stops `rebase --continue`, so the
    /// button says so instead of failing when pressed.
    func testUnstagedWorkBlocksTheSequencerOperations() {
        let files = [GitFileStatus(path: "keep.txt", indexStatus: ".", workTreeStatus: "M")]
        for operation in [GitService.InProgressOperation.rebase, .cherryPick, .revert] {
            XCTAssertEqual(
                InProgressOperationBanner.continueBlocker(
                    operation: operation, files: files, flattenedConflictCount: 0
                ),
                "git refuses to continue with unstaged changes — stage or discard them first",
                "\(operation)"
            )
        }
    }

    /// A merge finishes with `git commit`, which does not mind them.
    func testUnstagedWorkDoesNotBlockAMerge() {
        let files = [GitFileStatus(path: "keep.txt", indexStatus: ".", workTreeStatus: "M")]
        XCTAssertNil(InProgressOperationBanner.continueBlocker(
            operation: .merge, files: files, flattenedConflictCount: 0
        ))
        XCTAssertEqual(
            InProgressOperationBanner.detail(operation: .merge, files: files, flattenedConflictCount: 0),
            "· all conflicts resolved"
        )
    }

    /// Untracked files are invisible to `git diff-files`, so they hold nothing
    /// up — and neither does a staged resolution.
    func testAStagedResolutionAlongsideUntrackedFilesCanContinue() {
        let files = [
            GitFileStatus(path: "a.txt", indexStatus: "M", workTreeStatus: "."),
            GitFileStatus(path: "notes.md", indexStatus: "?", workTreeStatus: "?"),
        ]
        XCTAssertNil(InProgressOperationBanner.continueBlocker(
            operation: .rebase, files: files, flattenedConflictCount: 0
        ))
        XCTAssertEqual(
            InProgressOperationBanner.detail(operation: .rebase, files: files, flattenedConflictCount: 0),
            "· all conflicts resolved"
        )
    }
}
