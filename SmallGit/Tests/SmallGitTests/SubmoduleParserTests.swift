import XCTest
@testable import SmallGit

/// Covers reading a repository's submodules.
///
/// Two sources have to be joined: `git submodule status` says what the index
/// records and what state each checkout is in, and `.gitmodules` supplies the
/// name and URL. Neither alone is enough, and they can legitimately disagree.
final class SubmoduleParserTests: XCTestCase {

    // MARK: - status

    /// The four markers, each of which means something the user acts on
    /// differently — that distinction is the whole reason state is parsed
    /// rather than inferred from the directory.
    func testEveryStatusMarkerIsRecognised() {
        let output = """
         a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2 lib/current (v1.0)
        -b1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2 lib/uninitialized
        +c1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2 lib/moved (heads/main)
        Ud1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2 lib/conflicted
        """
        let parsed = GitOutputParser.parseSubmoduleStatus(output)

        XCTAssertEqual(parsed.map(\.path),
                       ["lib/current", "lib/uninitialized", "lib/moved", "lib/conflicted"])
        XCTAssertEqual(parsed.map(\.state),
                       [.current, .uninitialized, .modified, .conflicted])
    }

    func testShaAndDescribeAreSeparated() throws {
        let line = " a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2 lib/foo (v1.2-3-gabc1234)"
        let entry = try XCTUnwrap(GitOutputParser.parseSubmoduleStatus(line).first)

        XCTAssertEqual(entry.sha, "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2")
        XCTAssertEqual(entry.describe, "v1.2-3-gabc1234")
        XCTAssertEqual(entry.path, "lib/foo")
    }

    /// An uninitialised submodule has no clone to describe, so git prints no
    /// suffix at all.
    func testAMissingDescribeIsNil() throws {
        let line = "-a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2 lib/foo"
        let entry = try XCTUnwrap(GitOutputParser.parseSubmoduleStatus(line).first)
        XCTAssertNil(entry.describe)
        XCTAssertEqual(entry.path, "lib/foo")
    }

    /// Splitting the line on whitespace would truncate this to "vendor/my".
    func testPathsContainingSpacesSurvive() throws {
        let line = " a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2 vendor/my lib (v1.0)"
        let entry = try XCTUnwrap(GitOutputParser.parseSubmoduleStatus(line).first)
        XCTAssertEqual(entry.path, "vendor/my lib")
        XCTAssertEqual(entry.describe, "v1.0")
    }

    /// Only the trailing parenthesised group is the describe.
    func testPathsContainingParenthesesSurvive() throws {
        let line = " a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2 vendor/lib (old) (v1.0)"
        let entry = try XCTUnwrap(GitOutputParser.parseSubmoduleStatus(line).first)
        XCTAssertEqual(entry.path, "vendor/lib (old)")
        XCTAssertEqual(entry.describe, "v1.0")
    }

    /// git writes warnings to the same stream; one must not become a row.
    func testUnrecognisedLinesAreSkipped() {
        let output = """
        warning: unable to rmdir 'lib/gone': Directory not empty
         a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2 lib/real (v1.0)
        """
        let parsed = GitOutputParser.parseSubmoduleStatus(output)
        XCTAssertEqual(parsed.map(\.path), ["lib/real"])
    }

    func testEmptyOutputIsNoSubmodules() {
        XCTAssertTrue(GitOutputParser.parseSubmoduleStatus("").isEmpty)
        XCTAssertTrue(GitOutputParser.parseSubmoduleStatus("\n\n").isEmpty)
    }

    // MARK: - .gitmodules

    func testGitmodulesYieldsNameAndURLKeyedByPath() {
        let contents = """
        [submodule "vendor-lib"]
        \tpath = vendor/lib
        \turl = https://github.com/org/lib.git
        [submodule "docs"]
        \tpath = docs
        \turl = git@github.com:org/docs.git
        \tbranch = main
        """
        let parsed = GitOutputParser.parseGitmodules(contents)

        XCTAssertEqual(parsed["vendor/lib"]?.name, "vendor-lib")
        XCTAssertEqual(parsed["vendor/lib"]?.url, "https://github.com/org/lib.git")
        XCTAssertEqual(parsed["docs"]?.name, "docs")
        XCTAssertEqual(parsed["docs"]?.url, "git@github.com:org/docs.git")
    }

    /// A name that differs from its path is legal and not unusual.
    func testNameAndPathAreKeptSeparate() {
        let parsed = GitOutputParser.parseGitmodules("""
        [submodule "friendly name"]
        \tpath = deeply/nested/thing
        \turl = https://example.com/x.git
        """)
        XCTAssertEqual(parsed["deeply/nested/thing"]?.name, "friendly name")
    }

    func testAMalformedFileYieldsNothingRatherThanFailing() {
        XCTAssertTrue(GitOutputParser.parseGitmodules("not ini at all").isEmpty)
        XCTAssertTrue(GitOutputParser.parseGitmodules("").isEmpty)
    }

    /// A section with no path cannot be keyed, and must not take a later
    /// section's path with it.
    func testASectionWithoutAPathIsDropped() {
        let parsed = GitOutputParser.parseGitmodules("""
        [submodule "broken"]
        \turl = https://example.com/x.git
        [submodule "fine"]
        \tpath = lib
        \turl = https://example.com/y.git
        """)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed["lib"]?.url, "https://example.com/y.git")
    }

    // MARK: - Merging

    func testMergeJoinsStatusWithTheGitmodulesRecord() throws {
        let submodules = GitOutputParser.mergeSubmodules(
            status: " a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2 vendor/lib (v1.0)",
            gitmodules: """
            [submodule "vendor-lib"]
            \tpath = vendor/lib
            \turl = https://github.com/org/lib.git
            """
        )
        let module = try XCTUnwrap(submodules.first)

        XCTAssertEqual(module.name, "vendor-lib")
        XCTAssertEqual(module.url, "https://github.com/org/lib.git")
        XCTAssertEqual(module.state, .current)
        XCTAssertEqual(module.shortSHA, "a1b2c3d")
    }

    /// The index is the authority. A submodule dropped from `.gitmodules` but
    /// still in the index exists, and that half-removed state is exactly when
    /// someone comes looking for it.
    func testASubmoduleMissingFromGitmodulesIsStillListed() throws {
        let submodules = GitOutputParser.mergeSubmodules(
            status: "-a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2 orphan/lib",
            gitmodules: ""
        )
        let module = try XCTUnwrap(submodules.first)

        XCTAssertEqual(module.path, "orphan/lib")
        XCTAssertEqual(module.name, "orphan/lib", "falls back to the path")
        XCTAssertNil(module.url)
        XCTAssertEqual(module.state, .uninitialized)
    }

    /// `.gitmodules` can list a submodule the index doesn't have — a pulled
    /// change not yet initialised. The listing follows the index.
    func testAGitmodulesEntryWithNoIndexRecordIsNotInvented() {
        let submodules = GitOutputParser.mergeSubmodules(
            status: "",
            gitmodules: """
            [submodule "ghost"]
            \tpath = ghost
            \turl = https://example.com/ghost.git
            """
        )
        XCTAssertTrue(submodules.isEmpty)
    }

    // MARK: - Model

    func testAbsolutePathJoinsOntoTheRepository() {
        let module = GitSubmodule(path: "vendor/lib", name: "lib", url: nil,
                                  sha: "abc", describe: nil, state: .current)
        XCTAssertEqual(module.absolutePath(in: "/repos/app"), "/repos/app/vendor/lib")
    }

    /// An uninitialised submodule is an empty directory, so opening it as a
    /// repository would add a broken entry to the sidebar.
    func testOnlyClonedSubmodulesCanBeOpened() {
        func module(_ state: GitSubmodule.State) -> GitSubmodule {
            GitSubmodule(path: "p", name: "p", url: nil, sha: "abc",
                         describe: nil, state: state)
        }
        XCTAssertFalse(module(.uninitialized).isCloned)
        XCTAssertTrue(module(.current).isCloned)
        XCTAssertTrue(module(.modified).isCloned)
        XCTAssertTrue(module(.conflicted).isCloned)
    }
}
