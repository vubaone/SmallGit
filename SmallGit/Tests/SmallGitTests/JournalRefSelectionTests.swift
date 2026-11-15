import XCTest
@testable import SmallGit

/// The Branches panel's checkboxes: which refs the journal graphs.
/// SmartGit's model — the graph is `git log <every ticked ref>`.
final class JournalRefSelectionTests: XCTestCase {

    func testHeadOnlyPassesNoRevisionsAtAll() {
        let selection = JournalRefSelection.headOnly
        XCTAssertTrue(selection.isHeadOnly)
        XCTAssertFalse(selection.isEmpty)
        XCTAssertEqual(selection.revisions, [],
            "the default view is plain `git log`, not `git log HEAD`")
    }

    func testTickedRefsBecomeRevisions() {
        var selection = JournalRefSelection(head: false, refs: [])
        selection.set("main", checked: true)
        selection.set("origin/feature", checked: true)
        XCTAssertEqual(selection.revisions, ["main", "origin/feature"])

        selection.head = true
        XCTAssertEqual(selection.revisions, ["HEAD", "main", "origin/feature"],
            "HEAD leads, and the rest are sorted so the args are stable")
    }

    func testUntickingRemovesTheRef() {
        var selection = JournalRefSelection(head: false, refs: ["main", "dev"])
        selection.set("dev", checked: false)
        XCTAssertEqual(selection.revisions, ["main"])
    }

    func testNothingTickedIsEmptyRatherThanEverything() {
        let selection = JournalRefSelection(head: false, refs: [])
        XCTAssertTrue(selection.isEmpty)
        XCTAssertFalse(selection.isHeadOnly)
        XCTAssertEqual(selection.revisions, [],
            "the caller must not run git here — no args would mean HEAD")
    }

    // MARK: - Group (tri-state) boxes

    func testGroupStateReflectsHowManyOfItsRefsAreTicked() {
        var selection = JournalRefSelection(head: true, refs: [])
        let group = ["a", "b", "c"]
        XCTAssertEqual(selection.state(of: group), .off)

        selection.set("b", checked: true)
        XCTAssertEqual(selection.state(of: group), .mixed)

        selection.set(group, checked: true)
        XCTAssertEqual(selection.state(of: group), .on)
    }

    func testAnEmptyGroupIsOffNotOn() {
        let selection = JournalRefSelection(head: true, refs: ["a"])
        XCTAssertEqual(selection.state(of: []), .off,
            "an empty folder must not read as fully ticked")
    }

    func testClickingAPartialGroupFillsItIn() {
        XCTAssertTrue(JournalRefSelection.CheckState.off.toggled)
        XCTAssertTrue(JournalRefSelection.CheckState.mixed.toggled)
        XCTAssertFalse(JournalRefSelection.CheckState.on.toggled,
            "a full group clears")
    }

    func testGroupToggleTouchesEveryRefUnderIt() {
        var selection = JournalRefSelection(head: true, refs: ["keep"])
        selection.set(["a", "b"], checked: true)
        XCTAssertEqual(selection.refs, ["keep", "a", "b"])
        selection.set(["a", "b"], checked: false)
        XCTAssertEqual(selection.refs, ["keep"], "unticking a group leaves the rest alone")
    }

    // MARK: - Cache identity

    func testHeadOnlyKeepsTheHistoricalCacheToken() {
        XCTAssertEqual(JournalRefSelection.headOnly.cacheToken,
                       CacheKey.currentBranchSentinel,
            "entries written before ref selection existed must still hit")
    }

    func testDifferentSelectionsGetDifferentCacheEntries() {
        let a = JournalRefSelection(head: false, refs: ["main"])
        let b = JournalRefSelection(head: false, refs: ["main", "dev"])
        let c = JournalRefSelection(head: true, refs: ["main"])
        XCTAssertNotEqual(a.cacheToken, b.cacheToken)
        XCTAssertNotEqual(a.cacheToken, c.cacheToken)
        XCTAssertNotEqual(a.cacheToken, CacheKey.currentBranchSentinel)
    }

    func testTheSameSelectionAlwaysHashesTheSame() {
        let a = JournalRefSelection(head: true, refs: ["b", "a"])
        let b = JournalRefSelection(head: true, refs: ["a", "b"])
        XCTAssertEqual(a.cacheToken, b.cacheToken,
            "a Set has no order — the token must not depend on one")
    }

    func testCacheTokenIsUsableAsAFilename() {
        let selection = JournalRefSelection(head: true, refs: ["origin/feature/a b"])
        let name = CacheKey.log(refs: selection.cacheToken).diskFileName
        XCTAssertFalse(name.contains("/"), "a ref name must not escape into a path")
        XCTAssertTrue(name.hasSuffix(".json"))
    }

    // MARK: - Pruning

    func testPruningForgetsDeletedRefs() {
        var selection = JournalRefSelection(head: true, refs: ["main", "gone", "origin/x"])
        selection.prune(keeping: ["main", "origin/x", "other"])
        XCTAssertEqual(selection.refs, ["main", "origin/x"])
        XCTAssertTrue(selection.head, "HEAD isn't a named ref and always survives")
    }

    func testCodableRoundTripForPersistence() throws {
        let selection = JournalRefSelection(head: false, refs: ["main", "v1.0"])
        let data = try JSONEncoder().encode(selection)
        let decoded = try JSONDecoder().decode(JournalRefSelection.self, from: data)
        XCTAssertEqual(decoded, selection)
    }

    /// Config files written before this feature carry no selection.
    func testRepositoryEntryDecodesWithoutASelection() throws {
        let json = """
        {"id":"\(UUID().uuidString)","path":"/tmp/x","name":"x","isFavorite":false}
        """
        let entry = try JSONDecoder().decode(RepositoryEntry.self, from: Data(json.utf8))
        XCTAssertNil(entry.logSelection)
    }
}
