import XCTest
@testable import SmallGit

/// Modify/delete conflicts — the kind git spells "deleted by us" and
/// "deleted by them". They used to arrive at the UI flattened into a
/// plain `UU` "Conflict", which hid the one fact that matters about
/// them: one side has no version of the file at all, so the checkout
/// that resolves a content conflict cannot work here.
final class DeleteConflictTests: XCTestCase {

    // MARK: - Parsing

    private func parseOne(_ xy: String) -> GitFileStatus {
        let raw = "u \(xy) N... 100644 100644 100644 100644 aaa bbb ccc src/gone.swift"
        let files = GitOutputParser.parseStatus(raw)
        return files[0]
    }

    func testUnmergedRecordKeepsItsRealStatusLetters() {
        let f = parseOne("UD")
        XCTAssertEqual(f.indexStatus, "U")
        XCTAssertEqual(f.workTreeStatus, "D")
        XCTAssertTrue(f.isConflict)
    }

    func testEveryUnmergedCodeMapsToItsKind() {
        let expected: [String: ConflictKind] = [
            "UU": .bothModified,
            "AA": .bothAdded,
            "DD": .bothDeleted,
            "AU": .addedByUs,
            "UA": .addedByThem,
            "DU": .deletedByUs,
            "UD": .deletedByThem,
        ]
        for (xy, kind) in expected {
            XCTAssertEqual(parseOne(xy).conflictKind, kind, "XY \(xy)")
        }
    }

    func testStateColumnNamesTheDeletingSide() {
        XCTAssertEqual(parseOne("DU").stateDisplay, "Deleted by us")
        XCTAssertEqual(parseOne("UD").stateDisplay, "Deleted by them")
        XCTAssertEqual(parseOne("AU").stateDisplay, "Added by us")
        XCTAssertEqual(parseOne("UA").stateDisplay, "Added by them")
        XCTAssertEqual(parseOne("DD").stateDisplay, "Both deleted")
        XCTAssertEqual(parseOne("AA").stateDisplay, "Both added")
    }

    /// The ordinary content clash keeps the word the column has always
    /// used — only the delete/add cases earn a longer name.
    func testOrdinaryContentConflictStillReadsConflict() {
        XCTAssertEqual(parseOne("UU").stateDisplay, "Conflict")
    }

    /// A conflicted row restored from a cache written before the letters
    /// were kept decodes as `UU`, which must stay harmless.
    func testUnknownCodeFallsBackToPlainConflict() {
        let f = GitFileStatus(path: "x", indexStatus: "?", workTreeStatus: "?", isConflict: true)
        XCTAssertNil(f.conflictKind)
        XCTAssertEqual(f.stateDisplay, "Conflict")
    }

    func testNonConflictRowHasNoKind() {
        XCTAssertNil(GitFileStatus(path: "x", indexStatus: "M", workTreeStatus: ".").conflictKind)
    }

    // MARK: - Which sides exist

    func testDeleteConflictsKnowWhichSideStillHasTheFile() {
        XCTAssertFalse(ConflictKind.deletedByUs.hasOurs)
        XCTAssertTrue(ConflictKind.deletedByUs.hasTheirs)
        XCTAssertTrue(ConflictKind.deletedByThem.hasOurs)
        XCTAssertFalse(ConflictKind.deletedByThem.hasTheirs)
        XCTAssertFalse(ConflictKind.bothDeleted.hasOurs)
        XCTAssertFalse(ConflictKind.bothDeleted.hasTheirs)
    }

    func testOnlyOneSidedCasesCountAsDeleteConflicts() {
        XCTAssertFalse(ConflictKind.bothModified.isDeleteConflict)
        XCTAssertFalse(ConflictKind.bothAdded.isDeleteConflict)
        XCTAssertTrue(ConflictKind.deletedByUs.isDeleteConflict)
        XCTAssertTrue(ConflictKind.deletedByThem.isDeleteConflict)
        XCTAssertTrue(ConflictKind.addedByUs.isDeleteConflict)
        XCTAssertTrue(ConflictKind.bothDeleted.isDeleteConflict)
    }

    /// The resolver window works the kind out from the stages that came
    /// back, not from `git status` — the ancestor is what separates a
    /// delete from an add.
    func testKindRebuiltFromPresentStages() {
        XCTAssertEqual(ConflictKind(hasBase: true,  hasOurs: true,  hasTheirs: true),  .bothModified)
        XCTAssertEqual(ConflictKind(hasBase: false, hasOurs: true,  hasTheirs: true),  .bothAdded)
        XCTAssertEqual(ConflictKind(hasBase: true,  hasOurs: false, hasTheirs: true),  .deletedByUs)
        XCTAssertEqual(ConflictKind(hasBase: false, hasOurs: false, hasTheirs: true),  .addedByThem)
        XCTAssertEqual(ConflictKind(hasBase: true,  hasOurs: true,  hasTheirs: false), .deletedByThem)
        XCTAssertEqual(ConflictKind(hasBase: false, hasOurs: true,  hasTheirs: false), .addedByUs)
        XCTAssertEqual(ConflictKind(hasBase: true,  hasOurs: false, hasTheirs: false), .bothDeleted)
        XCTAssertNil(ConflictKind(hasBase: false, hasOurs: false, hasTheirs: false))
    }

    // MARK: - The three-way view still works with a side missing

    /// The point of keeping the panes for a modify/delete: BASE against
    /// the side that survived is what that branch actually did to the
    /// file, which is what you need in order to judge the delete.
    func testAlignmentShowsWhatTheSurvivingSideChanged() {
        let base   = ["let a = 1", "let b = 2", "let c = 3"]
        let theirs = ["let a = 1", "let b = 22", "let c = 3", "let d = 4"]
        let rows = ConflictLineDiff.compute(base: base, ours: [], theirs: theirs, hasBase: true)

        XCTAssertFalse(rows.isEmpty, "an empty ours side must not collapse the alignment")
        // Every base line is present and every ours cell is absent — that
        // absence is the deletion, drawn line by line.
        XCTAssertTrue(rows.allSatisfy { $0.ours == nil })
        XCTAssertEqual(rows.compactMap { $0.base?.text }, base)
        // Their edit and their new line both survive into the view.
        let theirLines = rows.compactMap { $0.theirs?.text }
        XCTAssertEqual(theirLines, theirs)
        XCTAssertTrue(rows.contains { $0.theirs?.text == "let b = 22" })
        XCTAssertTrue(rows.contains { $0.theirs?.text == "let d = 4" })
    }

    func testAlignmentSurvivesADeletedIncomingSide() {
        let base = ["x", "y"]
        let ours = ["x", "y2"]
        let rows = ConflictLineDiff.compute(base: base, ours: ours, theirs: [], hasBase: true)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.theirs == nil })
        XCTAssertEqual(rows.compactMap { $0.ours?.text }, ours)
    }

    // MARK: - End-to-end against a real git

    @MainActor
    func testResolverNamesTheDeletedPane() {
        let vm = ConflictResolutionViewModel(coordinator: CacheCoordinator())
        vm.conflictKind = .deletedByUs
        XCTAssertEqual(vm.deletedSides, [.ours])
        vm.conflictKind = .deletedByThem
        XCTAssertEqual(vm.deletedSides, [.theirs])
        vm.conflictKind = .bothModified
        XCTAssertTrue(vm.deletedSides.isEmpty)
    }

    /// `ours.txt` is deleted on main and edited on `feature` (DU), while
    /// `theirs.txt` is edited on main and deleted on `feature` (UD). One
    /// merge produces both directions at once.
    private func makeDeleteConflictRepo() async throws
        -> (runner: ProcessRunner, git: GitService, path: String, root: URL) {
        let runner = ProcessRunner()
        do { _ = try await runner.gitExecutablePath() } catch {
            throw XCTSkip("git not available")
        }
        let git = GitService(runner: runner)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smallgit-delconflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = root.path

        _ = try await runner.run(in: repo, args: ["init", "-q", "-b", "main"])
        _ = try await runner.run(in: repo, args: ["config", "user.email", "t@x"])
        _ = try await runner.run(in: repo, args: ["config", "user.name",  "T"])
        _ = try await runner.run(in: repo, args: ["config", "commit.gpgsign", "false"])

        let ours   = root.appendingPathComponent("ours.txt")
        let theirs = root.appendingPathComponent("theirs.txt")
        try "base\n".write(to: ours,   atomically: true, encoding: .utf8)
        try "base\n".write(to: theirs, atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "-A"])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "base"])

        _ = try await runner.run(in: repo, args: ["checkout", "-q", "-b", "feature"])
        try "theirs-version\n".write(to: ours, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: theirs)
        _ = try await runner.run(in: repo, args: ["add", "-A"])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "feature"])

        _ = try await runner.run(in: repo, args: ["checkout", "-q", "main"])
        try FileManager.default.removeItem(at: ours)
        try "ours-version\n".write(to: theirs, atomically: true, encoding: .utf8)
        _ = try await runner.run(in: repo, args: ["add", "-A"])
        _ = try await runner.run(in: repo, args: ["commit", "-q", "-m", "main"])

        _ = try await runner.run(in: repo, args: ["merge", "--no-edit", "feature"])
        return (runner, git, repo, root)
    }

    private func exists(_ s: (path: String, root: URL), _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: s.root.appendingPathComponent(name).path)
    }

    func testStatusLabelsBothDirectionsOfAModifyDelete() async throws {
        let s = try await makeDeleteConflictRepo()
        defer { try? FileManager.default.removeItem(at: s.root) }

        let files = try await s.git.status(repoPath: s.path)
        XCTAssertEqual(files.first { $0.path == "ours.txt"   }?.conflictKind, .deletedByUs)
        XCTAssertEqual(files.first { $0.path == "theirs.txt" }?.conflictKind, .deletedByThem)
        XCTAssertEqual(files.first { $0.path == "ours.txt"   }?.stateDisplay, "Deleted by us")
        XCTAssertEqual(files.first { $0.path == "theirs.txt" }?.stateDisplay, "Deleted by them")
    }

    func testConflictStagesReportOnlyTheSidesThatExist() async throws {
        let s = try await makeDeleteConflictRepo()
        defer { try? FileManager.default.removeItem(at: s.root) }

        // Deleted by us: ancestor + theirs, no stage 2.
        let ours = try await s.git.conflictStages(repoPath: s.path, path: "ours.txt")
        XCTAssertEqual(ours, [1, 3])
        // Deleted by them: ancestor + ours, no stage 3.
        let theirs = try await s.git.conflictStages(repoPath: s.path, path: "theirs.txt")
        XCTAssertEqual(theirs, [1, 2])
    }

    /// The regression this all started from: `git checkout --ours` fails
    /// with "does not have our version" when our side deleted the file,
    /// so Take Ours used to throw and leave the conflict standing.
    func testAcceptOursOnAFileWeDeletedFinishesTheDelete() async throws {
        let s = try await makeDeleteConflictRepo()
        defer { try? FileManager.default.removeItem(at: s.root) }

        _ = try await s.git.acceptOurs(repoPath: s.path, path: "ours.txt")

        XCTAssertFalse(exists((s.path, s.root), "ours.txt"),
            "taking our side of a file we deleted should remove it")
        // HEAD already has it deleted, so once the index agrees there is
        // nothing left for status to report — no row at all is the
        // resolved state here, and specifically not a conflicted one.
        let entry = try await s.git.status(repoPath: s.path).first { $0.path == "ours.txt" }
        XCTAssertFalse(entry?.isConflict ?? false, "the conflict should be resolved")
        let stages = try await s.git.conflictStages(repoPath: s.path, path: "ours.txt")
        XCTAssertTrue(stages.isEmpty, "no unmerged index entry should remain")
    }

    func testAcceptTheirsOnAFileTheyDeletedFinishesTheDelete() async throws {
        let s = try await makeDeleteConflictRepo()
        defer { try? FileManager.default.removeItem(at: s.root) }

        _ = try await s.git.acceptTheirs(repoPath: s.path, path: "theirs.txt")

        XCTAssertFalse(exists((s.path, s.root), "theirs.txt"))
        let entry = try await s.git.status(repoPath: s.path).first { $0.path == "theirs.txt" }
        XCTAssertFalse(entry?.isConflict ?? false)
        XCTAssertTrue(entry?.isStaged ?? false)
    }

    func testAcceptTheirsOnAFileWeDeletedKeepsTheirVersion() async throws {
        let s = try await makeDeleteConflictRepo()
        defer { try? FileManager.default.removeItem(at: s.root) }

        _ = try await s.git.acceptTheirs(repoPath: s.path, path: "ours.txt")

        let text = try String(
            contentsOf: s.root.appendingPathComponent("ours.txt"), encoding: .utf8
        )
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "theirs-version")
        let entry = try await s.git.status(repoPath: s.path).first { $0.path == "ours.txt" }
        XCTAssertFalse(entry?.isConflict ?? false)
    }

    func testAcceptOursOnAFileTheyDeletedKeepsOurVersion() async throws {
        let s = try await makeDeleteConflictRepo()
        defer { try? FileManager.default.removeItem(at: s.root) }

        _ = try await s.git.acceptOurs(repoPath: s.path, path: "theirs.txt")

        let text = try String(
            contentsOf: s.root.appendingPathComponent("theirs.txt"), encoding: .utf8
        )
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "ours-version")
        let entry = try await s.git.status(repoPath: s.path).first { $0.path == "theirs.txt" }
        XCTAssertFalse(entry?.isConflict ?? false)
    }

    /// A hand edit left in the working tree must not stop the delete
    /// resolution — `git rm` on an unmerged path takes it either way.
    func testDeleteResolutionSurvivesALocalEdit() async throws {
        let s = try await makeDeleteConflictRepo()
        defer { try? FileManager.default.removeItem(at: s.root) }

        try "hand edit\n".write(
            to: s.root.appendingPathComponent("theirs.txt"), atomically: true, encoding: .utf8
        )
        _ = try await s.git.acceptTheirs(repoPath: s.path, path: "theirs.txt")
        XCTAssertFalse(exists((s.path, s.root), "theirs.txt"))
    }
}
