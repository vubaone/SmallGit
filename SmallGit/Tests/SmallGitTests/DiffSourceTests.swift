import XCTest
@testable import SmallGit

final class DiffSourceTests: XCTestCase {

    func testTitleAndFile() {
        XCTAssertEqual(DiffSource.none.title, "Changes")
        XCTAssertNil(DiffSource.none.file)

        let unstaged: DiffSource = .fileChanges(file: "a/b.swift", mode: .indexVsWorkingTree)
        XCTAssertEqual(unstaged.title, "Changes of a/b.swift")
        XCTAssertEqual(unstaged.file, "a/b.swift")

        let staged: DiffSource = .fileChanges(file: "x.swift", mode: .headVsIndex)
        XCTAssertEqual(staged.title, "Staged changes of x.swift")
        XCTAssertTrue(staged.staged)

        XCTAssertEqual(DiffSource.stash(index: 3, path: nil).title, "Stash @{3}")
        XCTAssertNil(DiffSource.stash(index: 3, path: nil).file)

        // Narrowed to one file, the title says which and `file` names it —
        // the diff rows are then syntax-coloured for that language.
        let oneFile: DiffSource = .stash(index: 3, path: "Sources/a.swift")
        XCTAssertEqual(oneFile.title, "Stash @{3} — Sources/a.swift")
        XCTAssertEqual(oneFile.file, "Sources/a.swift")
        // Naming a file must not make a stash stageable: `git apply --cached`
        // has nothing to apply against for a revision that isn't the index.
        XCTAssertFalse(oneFile.isStageable)
    }

    func testIsStageable() {
        XCTAssertTrue(DiffSource.fileChanges(file: "a", mode: .indexVsWorkingTree).isStageable)
        XCTAssertTrue(DiffSource.fileChanges(file: "a", mode: .headVsIndex).isStageable)
        XCTAssertFalse(DiffSource.stash(index: 0, path: nil).isStageable)
        XCTAssertFalse(DiffSource.none.isStageable)
    }

    func testStagedFlag() {
        XCTAssertFalse(DiffSource.fileChanges(file: "a", mode: .indexVsWorkingTree).staged)
        XCTAssertTrue(DiffSource.fileChanges(file: "a", mode: .headVsIndex).staged)
        XCTAssertFalse(DiffSource.stash(index: 0, path: nil).staged)
        XCTAssertFalse(DiffSource.none.staged)
    }

    func testCompareMode() {
        XCTAssertEqual(
            DiffSource.fileChanges(file: "a", mode: .headVsIndex).compareMode,
            .headVsIndex
        )
        XCTAssertNil(DiffSource.none.compareMode)
        XCTAssertNil(DiffSource.stash(index: 0, path: nil).compareMode)
        XCTAssertNil(DiffSource.conflict(file: "a").compareMode)
        XCTAssertNil(DiffSource.untrackedFile(file: "a").compareMode)
    }
}
