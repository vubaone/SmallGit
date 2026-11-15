import XCTest
@testable import SmallGit

/// Covers taking the common ancestor for a conflict chunk.
///
/// Beyond Compare calls it "Take Center" and KDiff3 calls it "A"; the
/// resolver showed a BASE pane but offered no way to take it. It is a
/// genuinely different outcome from "Neither", which deletes the region —
/// the two are easy to confuse and produce opposite results.
final class ConflictBaseResolutionTests: XCTestCase {

    /// diff3 style — git writes the ancestor into a `|||||||` section.
    private let diff3 = """
    line before
    <<<<<<< HEAD
    ours change
    ||||||| merged common ancestors
    original text
    =======
    theirs change
    >>>>>>> feature
    line after
    """

    /// The default `merge` style — ours and theirs only, no ancestor.
    private let plain = """
    line before
    <<<<<<< HEAD
    ours change
    =======
    theirs change
    >>>>>>> feature
    line after
    """

    // MARK: - Parsing

    func testDiff3StyleCarriesTheAncestor() throws {
        let chunk = try XCTUnwrap(ConflictParser.parse(diff3).chunks.first)
        XCTAssertEqual(chunk.baseText, "original text\n")
        XCTAssertEqual(chunk.oursText, "ours change\n")
        XCTAssertEqual(chunk.theirsText, "theirs change\n")
    }

    /// git's default style simply does not contain the ancestor, which is why
    /// the button has to be disabled rather than silently doing nothing.
    func testDefaultStyleHasNoAncestorToTake() throws {
        let chunk = try XCTUnwrap(ConflictParser.parse(plain).chunks.first)
        XCTAssertNil(chunk.baseText)
    }

    // MARK: - Resolution

    func testTakingBaseRestoresTheAncestor() throws {
        let chunk = try XCTUnwrap(ConflictParser.parse(diff3).chunks.first)
        XCTAssertEqual(chunk.resolvedText(.base), "original text\n")
    }

    /// The distinction the button labels have to make obvious: one restores
    /// the original, the other deletes the region outright.
    func testBaseAndNeitherAreOppositeOutcomes() throws {
        let chunk = try XCTUnwrap(ConflictParser.parse(diff3).chunks.first)
        XCTAssertEqual(chunk.resolvedText(.base), "original text\n")
        XCTAssertEqual(chunk.resolvedText(.neither), "")
        XCTAssertNotEqual(chunk.resolvedText(.base), chunk.resolvedText(.neither))
    }

    /// Taking base with no base available must not delete the user's code.
    /// The UI disables the option, so this only guards a stored resolution
    /// outliving the conflict style its file was written in — but "silently
    /// wipes a chunk" is the wrong way to fail.
    func testTakingBaseWithoutOneLeavesTheChunkIntact() throws {
        let chunk = try XCTUnwrap(ConflictParser.parse(plain).chunks.first)
        XCTAssertEqual(chunk.resolvedText(.base), chunk.originalBlock)
        XCTAssertNotEqual(chunk.resolvedText(.base), "")
    }

    func testOtherResolutionsAreUnaffected() throws {
        let chunk = try XCTUnwrap(ConflictParser.parse(diff3).chunks.first)
        XCTAssertEqual(chunk.resolvedText(.ours), "ours change\n")
        XCTAssertEqual(chunk.resolvedText(.theirs), "theirs change\n")
        XCTAssertEqual(chunk.resolvedText(.bothOursFirst), "ours change\ntheirs change\n")
        XCTAssertEqual(chunk.resolvedText(.bothTheirsFirst), "theirs change\nours change\n")
        XCTAssertEqual(chunk.resolvedText(.unresolved), chunk.originalBlock)
    }

    /// Reassembling with a base resolution must round-trip the untouched
    /// parts of the file exactly.
    func testResolvedFileKeepsTheSurroundingText() throws {
        let parsed = ConflictParser.parse(diff3)
        let chunk = try XCTUnwrap(parsed.chunks.first)
        let rebuilt = parsed.segments[0] + chunk.resolvedText(.base) + parsed.segments[1]

        XCTAssertTrue(rebuilt.hasPrefix("line before\n"))
        XCTAssertTrue(rebuilt.hasSuffix("line after"))
        XCTAssertTrue(rebuilt.contains("original text"))
        XCTAssertFalse(rebuilt.contains("<<<<<<<"))
        XCTAssertFalse(rebuilt.contains("ours change"))
        XCTAssertFalse(rebuilt.contains("theirs change"))
    }

    /// The real file this was reported on: the whole file is one conflict
    /// block, no surrounding context. "Neither" therefore empties it —
    /// correctly, which is why the merged pane now says so rather than just
    /// showing nothing.
    func testNeitherEmptiesAFileThatIsNothingButAConflict() throws {
        let wholeFileIsAConflict = """
        <<<<<<< HEAD
        Line edited on branch A.
        =======
        Line edited on branch B.
        >>>>>>> conflict/b

        """
        let parsed = ConflictParser.parse(wholeFileIsAConflict)
        let chunk = try XCTUnwrap(parsed.chunks.first)

        let rebuilt = parsed.segments[0] + chunk.resolvedText(.neither) + parsed.segments[1]

        XCTAssertTrue(rebuilt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      "with no context around it, dropping both sides leaves nothing")
    }

    /// The same choice on a file that *does* have context keeps that context —
    /// so an empty result really is about the file, not about the resolver
    /// discarding anything it shouldn't.
    func testNeitherKeepsSurroundingContextWhenThereIsAny() throws {
        let parsed = ConflictParser.parse(plain)
        let chunk = try XCTUnwrap(parsed.chunks.first)

        let rebuilt = parsed.segments[0] + chunk.resolvedText(.neither) + parsed.segments[1]

        XCTAssertEqual(rebuilt, "line before\nline after")
    }

    /// `zdiff3` labels the section differently but uses the same marker.
    func testZdiff3StyleIsAlsoRecognised() throws {
        let zdiff3 = """
        <<<<<<< ours
        a
        ||||||| base
        b
        =======
        c
        >>>>>>> theirs
        """
        let chunk = try XCTUnwrap(ConflictParser.parse(zdiff3).chunks.first)
        XCTAssertEqual(chunk.baseText, "b")
    }
}
