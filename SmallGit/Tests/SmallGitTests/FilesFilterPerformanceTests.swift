import XCTest
@testable import SmallGit

/// What the Files panel costs to read.
///
/// The reported hang: filtering a large repository lists thousands of
/// tracked paths, and selecting them all froze the app. Nothing about a
/// selection needs the rows rebuilt — the list is already there — but
/// `filteredFiles` was a computed property that re-filtered every changed
/// file, re-folded every tracked path and re-sorted the result on every
/// read, and a selection change causes many reads.
@MainActor
final class FilesFilterPerformanceTests: XCTestCase {

    private func makeViewModel(trackedPaths: Int) -> FilesViewModel {
        let vm = FilesViewModel(coordinator: CacheCoordinator())
        vm.setTrackedPathsForTesting(
            (0..<trackedPaths).map { "srcs/plugins/Module\($0 % 40)/File\($0)yield.swift" }
        )
        vm.files = (0..<200).map {
            GitFileStatus(path: "changed/File\($0)yield.swift", indexStatus: "M", workTreeStatus: ".")
        }
        return vm
    }

    func testTheFinderIsCappedButNeverHidesAChangedFile() {
        let vm = makeViewModel(trackedPaths: 40_000)
        vm.filterText = "y"

        let rows = vm.filteredFiles
        let unchanged = rows.filter { $0.state == .unmodified }
        let changed = rows.filter { $0.state != .unmodified }

        XCTAssertEqual(unchanged.count, FilesViewModel.maxUnchangedMatches,
                       "a finder shows the top matches, not every one of them")
        XCTAssertEqual(changed.count, 200,
                       "everything that changed is always listed — that is the panel's actual job")
        XCTAssertGreaterThan(vm.truncatedMatchCount, 0, "and it says how many it left out")
        XCTAssertEqual(
            unchanged.count + vm.truncatedMatchCount + changed.count,
            40_000 + 200,
            "shown plus left out accounts for everything that matched"
        )
    }

    func testASmallResultIsNotReportedAsTruncated() {
        let vm = makeViewModel(trackedPaths: 40_000)
        // Narrow enough to fit under the cap.
        vm.filterText = "file1yield"
        XCTAssertEqual(vm.truncatedMatchCount, 0)
    }

    func testHiddenCountIsCachedWithTheRows() {
        let vm = makeViewModel(trackedPaths: 40_000)
        vm.filterText = "y"
        let first = vm.hiddenCount

        // It unions every tracked path, and the header reads it on every
        // pass — so it has to be as cached as the rows are.
        let clock = Date()
        for _ in 0..<200 { _ = vm.hiddenCount }
        let elapsed = Date().timeIntervalSince(clock)
        XCTAssertLessThan(elapsed, 1.0, "200 reads took \(elapsed)s")

        vm.filterText = "file1yield"
        XCTAssertNotEqual(vm.hiddenCount, first, "and still notice when the filter changes")
    }

    func testRepeatedReadsAreServedFromCache() {
        let vm = makeViewModel(trackedPaths: 40_000)
        vm.filterText = "y"
        let first = vm.filteredFiles
        XCTAssertGreaterThan(first.count, 200, "changed files plus a capped page of matches")

        // A selection change re-reads the rows many times over; each read
        // used to redo the whole job.
        let clock = Date()
        for _ in 0..<200 {
            _ = vm.filteredFiles
        }
        let elapsed = Date().timeIntervalSince(clock)
        XCTAssertLessThan(elapsed, 1.0, "200 reads took \(elapsed)s — the cache is not holding")
    }

    func testTheCacheStillNoticesEveryInput() {
        let vm = makeViewModel(trackedPaths: 2_000)
        vm.filterText = "y"
        let base = vm.filteredFiles.count
        XCTAssertGreaterThan(base, 0)

        // Each of these feeds `filteredFiles`, and a cache that missed one
        // would quietly show the wrong list — worse than the slow version.
        vm.filterText = "File1yield"
        XCTAssertNotEqual(vm.filteredFiles.count, base, "filter text")

        vm.filterText = "y"
        XCTAssertEqual(vm.filteredFiles.count, base)

        vm.files.append(GitFileStatus(path: "brand/yield.swift", indexStatus: "A", workTreeStatus: "."))
        XCTAssertEqual(vm.filteredFiles.count, base + 1, "changed files")

        vm.showStaged = false
        XCTAssertNotEqual(vm.filteredFiles.count, base + 1, "type filters")
        vm.showStaged = true

        vm.setTrackedPathsForTesting([])
        XCTAssertLessThan(vm.filteredFiles.count, base, "tracked paths")
        XCTAssertEqual(vm.truncatedMatchCount, 0, "and the truncation count follows the rows")

        vm.sortOrder = [FileSortComparator(field: .name)]
        let sorted = vm.filteredFiles
        XCTAssertEqual(sorted, sorted.sorted(using: vm.sortOrder), "sort order")
    }
}
