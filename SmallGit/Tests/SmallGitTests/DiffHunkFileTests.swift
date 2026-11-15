import XCTest
@testable import SmallGit

/// Covers the file path the diff parser now records per hunk.
///
/// It exists so a multi-file diff — a commit, a stash — can be syntax
/// coloured correctly. Without it the view has one language for the whole
/// stream, and a commit touching both Swift and Markdown lights the prose up
/// with keywords.
final class DiffHunkFileTests: XCTestCase {

    func testHeaderPathIsExtracted() {
        XCTAssertEqual(
            GitOutputParser.pathFromGitDiffHeader("diff --git a/src/main.swift b/src/main.swift"),
            "src/main.swift"
        )
    }

    /// Renames have different a/ and b/ sides. The post-image is the name the
    /// file now has, which is the one whose extension should decide.
    func testRenamePrefersTheNewName() {
        XCTAssertEqual(
            GitOutputParser.pathFromGitDiffHeader("diff --git a/old.txt b/new.swift"),
            "new.swift"
        )
    }

    /// git quotes paths containing spaces, and ` b/` also occurs inside the
    /// quoted form — so the quoted case has to be tried first.
    func testQuotedPathsWithSpaces() {
        XCTAssertEqual(
            GitOutputParser.pathFromGitDiffHeader(#"diff --git "a/my file.swift" "b/my file.swift""#),
            "my file.swift"
        )
    }

    /// A path that itself contains " b/" must not truncate at the wrong one.
    func testPathContainingTheDelimiter() {
        XCTAssertEqual(
            GitOutputParser.pathFromGitDiffHeader("diff --git a/x b/lib b/lib"),
            "lib"
        )
    }

    func testMalformedHeaderIsNil() {
        XCTAssertNil(GitOutputParser.pathFromGitDiffHeader("diff --git"))
    }

    /// The point of the whole change: each hunk knows its own file.
    func testEachHunkInAMultiFileDiffCarriesItsOwnPath() {
        let output = """
        diff --git a/src/main.swift b/src/main.swift
        index 111..222 100644
        --- a/src/main.swift
        +++ b/src/main.swift
        @@ -1,2 +1,2 @@
        -let a = 1
        +let a = 2
        diff --git a/docs/guide.md b/docs/guide.md
        index 333..444 100644
        --- a/docs/guide.md
        +++ b/docs/guide.md
        @@ -1,1 +1,1 @@
        -old prose
        +new prose
        """
        let hunks = GitOutputParser.parseDiff(output)

        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(hunks.first?.file, "src/main.swift")
        XCTAssertEqual(hunks.last?.file, "docs/guide.md")
        XCTAssertEqual(SyntaxLanguage(path: hunks.first?.file ?? ""), .swift)
        XCTAssertNil(SyntaxLanguage(path: hunks.last?.file ?? ""),
                     "Markdown stays uncoloured even in a diff whose other half is Swift")
    }

    /// Two hunks in the same file both carry it.
    func testEveryHunkOfOneFileCarriesThePath() {
        let output = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,1 +1,1 @@
        -x
        +y
        @@ -10,1 +10,1 @@
        -p
        +q
        """
        let hunks = GitOutputParser.parseDiff(output)
        XCTAssertEqual(hunks.count, 2)
        XCTAssertTrue(hunks.allSatisfy { $0.file == "a.swift" })
    }

    /// A removed line whose content begins with `--` must not be mistaken for
    /// a header, and must not clear the file the hunk belongs to. Anchoring on
    /// `diff --git` rather than on `---` is what makes this hold.
    func testRemovedLinesStartingWithDashesDoNotClearThePath() {
        let output = """
        diff --git a/notes.swift b/notes.swift
        --- a/notes.swift
        +++ b/notes.swift
        @@ -1,2 +1,1 @@
        -let x = 1
        +let y = 2
        """
        let hunks = GitOutputParser.parseDiff(output)
        XCTAssertEqual(hunks.first?.file, "notes.swift")
    }

    /// Hunks cached before the field existed decode with `file == nil` rather
    /// than failing the whole cache entry.
    func testHunksWithoutAFileFieldStillDecode() throws {
        let legacy = Data("""
        {"id":"\(UUID().uuidString)","oldStart":1,"oldCount":1,"newStart":1,"newCount":1,"lines":[]}
        """.utf8)
        let hunk = try JSONDecoder().decode(DiffHunk.self, from: legacy)
        XCTAssertNil(hunk.file)
        XCTAssertEqual(hunk.oldStart, 1)
    }
}
