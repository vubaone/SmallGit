import XCTest
@testable import SmallGit

final class GitOutputParserTests: XCTestCase {

    func testParseStatusOrdinaryAndUntracked() {
        let raw = """
        1 .M N... 100644 100644 100644 abcd1234 abcd1234 src/foo.swift
        1 M. N... 100644 100644 100644 1111 2222 src/bar.swift
        ? README.md
        """
        let files = GitOutputParser.parseStatus(raw)
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files[0].path, "src/foo.swift")
        XCTAssertTrue(files[0].isUnstaged)
        XCTAssertEqual(files[1].path, "src/bar.swift")
        XCTAssertTrue(files[1].isStaged)
        XCTAssertEqual(files[2].state, .untracked)
    }

    func testParseStatusRenamed() {
        let raw = "2 R. N... 100644 100644 100644 aaa bbb R100 new/path.swift\told/path.swift"
        let files = GitOutputParser.parseStatus(raw)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "new/path.swift")
        XCTAssertEqual(files[0].originalPath, "old/path.swift")
    }

    func testParseStatusZPreservesOddPaths() {
        let nul = "\u{0}"
        let raw = [
            "1 .M N... 100644 100644 100644 abcd1234 abcd1234 dir/file with spaces\tand tab.swift",
            "? notes/line\nbreak.txt"
        ].joined(separator: nul) + nul

        let files = GitOutputParser.parseStatus(raw)

        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].path, "dir/file with spaces\tand tab.swift")
        XCTAssertEqual(files[1].path, "notes/line\nbreak.txt")
        XCTAssertEqual(files[1].state, .untracked)
    }

    func testParseStatusZRenamedUsesFollowingRecordAsOriginalPath() {
        let nul = "\u{0}"
        let raw = "2 R. N... 100644 100644 100644 aaa bbb R100 new name.swift"
            + nul
            + "old\tname.swift"
            + nul

        let files = GitOutputParser.parseStatus(raw)

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "new name.swift")
        XCTAssertEqual(files[0].originalPath, "old\tname.swift")
    }

    func testParseBlameLinePorcelain() {
        let raw = """
        abc123def4567890abc123def4567890abc12345 1 1 2
        author Ada Lovelace
        author-mail <ada@example.com>
        author-time 1700000000
        author-tz +0000
        committer Ada Lovelace
        committer-time 1700000000
        committer-tz +0000
        summary First line of work
        filename src/foo.swift
        \tlet x = 1
        abc123def4567890abc123def4567890abc12345 2 2
        author Ada Lovelace
        author-mail <ada@example.com>
        author-time 1700000000
        author-tz +0000
        summary First line of work
        filename src/foo.swift
        \tlet y = 2
        """
        let lines = GitOutputParser.parseBlame(raw)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].lineNumber, 1)
        XCTAssertEqual(lines[0].author, "Ada Lovelace")
        XCTAssertEqual(lines[0].content, "let x = 1")
        XCTAssertEqual(lines[0].summary, "First line of work")
        XCTAssertEqual(lines[0].shortHash, "abc123de")
        XCTAssertEqual(lines[1].lineNumber, 2)
        XCTAssertEqual(lines[1].content, "let y = 2")
    }

    func testParseBlameBoundaryAndEmptyLine() {
        let raw = """
        ffffffffffffffffffffffffffffffffffffffff 5 5 1
        author Root
        author-time 1600000000
        summary Initial
        boundary
        filename a.txt
        \t
        """
        let lines = GitOutputParser.parseBlame(raw)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].isBoundary)
        XCTAssertEqual(lines[0].lineNumber, 5)
        XCTAssertEqual(lines[0].content, "")
    }

    func testParseStatusConflict() {
        let raw = "u UU N... 100644 100644 100644 100644 aaa bbb ccc src/conflict.swift"
        let files = GitOutputParser.parseStatus(raw)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].isConflict)
        XCTAssertEqual(files[0].state, .conflict)
    }

    func testParseBranches() {
        // Use literal NULs since the parser splits on \0
        let nul = "\u{0}"
        let raw = [
            "main\(nul)origin/main\(nul)\(nul)*",
            "feature/login\(nul)origin/feature/login\(nul)\(nul)"
        ].joined(separator: "\n")
        let branches = GitOutputParser.parseBranches(raw)
        XCTAssertEqual(branches.count, 2)
        XCTAssertEqual(branches[0].name, "main")
        XCTAssertTrue(branches[0].isHead)
        XCTAssertEqual(branches[0].upstream, "origin/main")
        XCTAssertEqual(branches[1].name, "feature/login")
        XCTAssertFalse(branches[1].isHead)
    }

    func testParseBranchesRemoteNameAndGone() {
        // Format: name \0 upstream \0 worktree \0 HEAD \0 remotename \0 track
        let nul = "\u{0}"
        let raw = [
            "main\(nul)origin/main\(nul)\(nul)*\(nul)origin\(nul)",
            "feature/wt\(nul)origin/feature/wt\(nul)/tmp/wt\(nul)\(nul)origin\(nul)ahead 1",
            "feature/gone\(nul)origin/feature/gone\(nul)\(nul)\(nul)origin\(nul)gone"
        ].joined(separator: "\n")
        let branches = GitOutputParser.parseBranches(raw)
        XCTAssertEqual(branches.count, 3)

        XCTAssertEqual(branches[0].upstreamRemote, "origin")
        XCTAssertFalse(branches[0].upstreamGone)

        XCTAssertEqual(branches[1].worktreePath, "/tmp/wt")
        XCTAssertFalse(branches[1].upstreamGone)

        XCTAssertEqual(branches[2].upstreamRemote, "origin")
        XCTAssertTrue(branches[2].upstreamGone)
    }

    func testParseRemoteBranchesFiltersHEADPointer() {
        // Real-world `git branch -r --format=...` output: a bare "origin"
        // (the resolved symbolic HEAD ref) plus optionally "origin/HEAD",
        // followed by the real branches. Both noise forms must be dropped.
        let nul = "\u{0}"
        let raw = [
            "origin\(nul)\(nul)\(nul)",
            "origin/HEAD\(nul)\(nul)\(nul)",
            "origin/main\(nul)\(nul)\(nul)",
            "origin/feature/x\(nul)\(nul)\(nul)"
        ].joined(separator: "\n")
        let branches = GitOutputParser.parseBranches(raw, remote: true)
        XCTAssertEqual(branches.map(\.name), ["origin/main", "origin/feature/x"])
        XCTAssertTrue(branches.allSatisfy(\.isRemote))
    }

    func testIsRemoteHeadRefPredicate() {
        XCTAssertTrue(GitOutputParser.isRemoteHeadRef("origin"))
        XCTAssertTrue(GitOutputParser.isRemoteHeadRef("origin/HEAD"))
        XCTAssertTrue(GitOutputParser.isRemoteHeadRef("upstream/HEAD"))
        XCTAssertFalse(GitOutputParser.isRemoteHeadRef("origin/main"))
        XCTAssertFalse(GitOutputParser.isRemoteHeadRef("origin/feature/x"))
    }

    func testParseLocalBranchesPreservesAllRefs() {
        // Local-branch parsing must NOT apply the remote HEAD filter, since
        // a local branch literally named "main" (no slash) is legitimate.
        let nul = "\u{0}"
        let raw = "main\(nul)\(nul)\(nul)*"
        let branches = GitOutputParser.parseBranches(raw, remote: false)
        XCTAssertEqual(branches.map(\.name), ["main"])
    }

    func testParseLog() {
        let nul = "\u{0}"
        let raw = [
            "abcdef1234\(nul)abcdef1\(nul)Initial commit\(nul)Jane Doe\(nul)jane@example.com\(nul)2026-05-17T11:00:00Z\(nul)HEAD -> main",
        ].joined(separator: "\n")
        let commits = GitOutputParser.parseLog(raw)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].shortHash, "abcdef1")
        XCTAssertEqual(commits[0].authorName, "Jane Doe")
        XCTAssertTrue(commits[0].isHead)
    }

    func testParseBinaryDiff() {
        let raw = """
        diff --git a/logo.png b/logo.png
        index 1234..5678 100644
        Binary files a/logo.png and b/logo.png differ
        """
        XCTAssertTrue(GitOutputParser.isBinaryDiff(raw))
        let hunks = GitOutputParser.parseDiff(raw)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].lines.count, 1)
        XCTAssertEqual(hunks[0].lines[0].type, .context)
        XCTAssertTrue(hunks[0].lines[0].content.contains("binary file"))
    }

    func testParseBinaryDiffGitFormat() {
        let raw = """
        diff --git a/data.bin b/data.bin
        index 0000..0001 100644
        GIT binary patch
        delta 27
        ...gibberish...
        """
        XCTAssertTrue(GitOutputParser.isBinaryDiff(raw))
        let hunks = GitOutputParser.parseDiff(raw)
        XCTAssertEqual(hunks.count, 1)
    }

    /// A commit or a stash is several files in one stream. One image in it
    /// used to make `parseDiff` call the whole thing binary and return a
    /// single "preview not available" line, hiding every text change beside
    /// it — and leaving those hunks with no file to be filtered by.
    func testParseMultiFileDiffWithOneBinaryFile() {
        let raw = """
        diff --git a/logo.png b/logo.png
        index 1234..5678 100644
        Binary files a/logo.png and b/logo.png differ
        diff --git a/notes.md b/notes.md
        --- a/notes.md
        +++ b/notes.md
        @@ -1,2 +1,2 @@
         intro
        -old line
        +new line
        """
        let hunks = GitOutputParser.parseDiff(raw)
        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(hunks[0].file, "logo.png")
        XCTAssertTrue(hunks[0].lines[0].content.contains("binary file"))
        XCTAssertEqual(hunks[1].file, "notes.md")
        XCTAssertEqual(hunks[1].lines.map(\.content), ["intro", "old line", "new line"])
    }

    func testParseNameStatus() {
        let raw = """
        M\ta.swift
        A\tdir/b.swift
        D\tgone.swift
        R100\told.swift\tnew.swift
        """
        let files = GitOutputParser.parseNameStatus(raw)
        XCTAssertEqual(files.map(\.path), ["a.swift", "dir/b.swift", "gone.swift", "new.swift"])
        XCTAssertEqual(files.map(\.state), [.modified, .added, .deleted, .renamed])
        XCTAssertEqual(files[3].originalPath, "old.swift")
    }

    func testParseDiffHunks() {
        let raw = """
        diff --git a/x.swift b/x.swift
        --- a/x.swift
        +++ b/x.swift
        @@ -1,3 +1,4 @@
         line one
        -old line
        +new line
        +added
         line three
        """
        let hunks = GitOutputParser.parseDiff(raw)
        XCTAssertEqual(hunks.count, 1)
        XCTAssertEqual(hunks[0].oldStart, 1)
        XCTAssertEqual(hunks[0].newStart, 1)
        let types = hunks[0].lines.map(\.type)
        XCTAssertEqual(types, [.context, .del, .add, .add, .context])
    }
}
