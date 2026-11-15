import XCTest
@testable import SmallGit

/// Covers the performance badge's arithmetic — the part that can be wrong
/// without anyone noticing, because a number on a badge looks equally
/// authoritative whether or not it means anything.
final class PerfReadingTests: XCTestCase {

    private func counters(
        cpuNanos: UInt64 = 0,
        memory: UInt64 = 0,
        diskRead: UInt64 = 0,
        diskWrite: UInt64 = 0,
        netIn: UInt64 = 0,
        netOut: UInt64 = 0
    ) -> PerfCounters {
        PerfCounters(
            cpuNanos: cpuNanos,
            memoryBytes: memory,
            diskReadBytes: diskRead,
            diskWriteBytes: diskWrite,
            netInBytes: netIn,
            netOutBytes: netOut
        )
    }

    func testAFullSecondOfCPUInOneSecondIsOneHundredPercent() {
        let reading = PerfReading(
            from: counters(cpuNanos: 0),
            to: counters(cpuNanos: 1_000_000_000),
            elapsed: 1
        )
        XCTAssertEqual(reading.cpuPercent, 100, accuracy: 0.001)
    }

    func testMoreThanOneCoreReadsAboveOneHundred() {
        // Two cores busy for a second is two seconds of CPU, and the badge
        // says so rather than clamping — the same convention Activity
        // Monitor uses, and the clamp would hide the interesting case.
        let reading = PerfReading(
            from: counters(cpuNanos: 0),
            to: counters(cpuNanos: 2_000_000_000),
            elapsed: 1
        )
        XCTAssertEqual(reading.cpuPercent, 200, accuracy: 0.001)
    }

    func testRatesAreBytesPerSecondOverTheElapsedTime() {
        let reading = PerfReading(
            from: counters(diskRead: 1_000, netIn: 4_000),
            to: counters(diskRead: 3_000, netIn: 6_000),
            elapsed: 2
        )
        XCTAssertEqual(reading.diskReadPerSecond, 1_000, accuracy: 0.001)
        XCTAssertEqual(reading.netInPerSecond, 1_000, accuracy: 0.001)
    }

    func testMemoryIsTheLatestLevelNotADifference() {
        let reading = PerfReading(
            from: counters(memory: 100),
            to: counters(memory: 250),
            elapsed: 1
        )
        XCTAssertEqual(reading.memoryBytes, 250, "a footprint is a level; subtracting two of them is not one")
    }

    func testACounterGoingBackwardsReadsAsZero() {
        // Interfaces come and go, and their counters go with them. Unsigned
        // subtraction the wrong way round traps; the wrapped value it would
        // otherwise print is nonsense the width of the address space.
        let reading = PerfReading(
            from: counters(cpuNanos: 5_000, diskRead: 9_000, netOut: 9_000),
            to: counters(cpuNanos: 0, diskRead: 0, netOut: 0),
            elapsed: 1
        )
        XCTAssertEqual(reading.cpuPercent, 0)
        XCTAssertEqual(reading.diskReadPerSecond, 0)
        XCTAssertEqual(reading.netOutPerSecond, 0)
    }

    func testNoElapsedTimeProducesNoRates() {
        let reading = PerfReading(
            from: counters(memory: 42, diskRead: 0),
            to: counters(memory: 42, diskRead: 1_000),
            elapsed: 0
        )
        XCTAssertEqual(reading.diskReadPerSecond, 0, "dividing by no time is not a rate")
        XCTAssertEqual(reading.memoryBytes, 42, "the level still holds")
    }

    // MARK: - Formatting

    func testBytesScaleToUnitsThatFitOnABadge() {
        XCTAssertEqual(PerfFormat.bytes(0), "0 B")
        XCTAssertEqual(PerfFormat.bytes(512), "512 B")
        XCTAssertEqual(PerfFormat.bytes(1536), "1.5 KB")
        XCTAssertEqual(PerfFormat.bytes(148 * 1024 * 1024), "148 MB")
        XCTAssertEqual(PerfFormat.rate(1024), "1.0 KB/s")
    }

    func testPercentIsWholeNumbers() {
        XCTAssertEqual(PerfFormat.percent(0), "0%")
        XCTAssertEqual(PerfFormat.percent(12.4), "12%")
        XCTAssertEqual(PerfFormat.percent(199.6), "200%")
    }
}

/// The sampler itself, driven by a fake clock and fake counters — nothing
/// here touches the kernel, so the test measures the logic rather than the
/// machine it happens to run on.
@MainActor
final class PerformanceSamplerTests: XCTestCase {

    func testTheFirstSampleHasNothingToCompareAgainst() {
        var now = Date(timeIntervalSince1970: 0)
        let sampler = PerformanceSampler(read: { PerfCounters() }, clock: { now })

        sampler.sample()
        XCTAssertNil(sampler.reading, "one reading is not a rate")

        now = now.addingTimeInterval(1)
        sampler.sample()
        XCTAssertNotNil(sampler.reading)
    }

    func testEachSampleMeasuresAgainstTheOneBefore() {
        var now = Date(timeIntervalSince1970: 0)
        var counters = PerfCounters()
        let sampler = PerformanceSampler(read: { counters }, clock: { now })

        sampler.sample()

        now = now.addingTimeInterval(1)
        counters.diskWriteBytes = 2_048
        counters.memoryBytes = 1_000
        sampler.sample()
        XCTAssertEqual(sampler.reading?.diskWritePerSecond, 2_048)

        // The second interval, not the total since launch: a burst that has
        // stopped should read as stopped.
        now = now.addingTimeInterval(1)
        sampler.sample()
        XCTAssertEqual(sampler.reading?.diskWritePerSecond, 0)
        XCTAssertEqual(sampler.reading?.memoryBytes, 1_000)
    }
}

/// The one part that has to talk to the kernel. Loose assertions on purpose:
/// the numbers depend on the machine, but "the call worked and returned
/// something possible" is exactly what breaks silently if the `rusage`
/// plumbing is wrong, and a badge of zeroes looks like an idle app.
final class PerfCountersLiveTests: XCTestCase {

    func testTheProcessReportsItsOwnCPUAndMemory() {
        let counters = PerfCounters.current()
        XCTAssertGreaterThan(counters.memoryBytes, 0, "a running process has a footprint")
        XCTAssertGreaterThan(counters.cpuNanos, 0, "and has spent some CPU getting here")
    }

    func testCPUTimeOnlyGoesUp() {
        let first = PerfCounters.current()
        // Something to actually burn a little CPU between the two reads.
        var sink = 0
        for i in 0..<200_000 { sink &+= i }
        XCTAssertGreaterThanOrEqual(sink, 0)
        let second = PerfCounters.current()
        XCTAssertGreaterThanOrEqual(second.cpuNanos, first.cpuNanos)
    }
}
