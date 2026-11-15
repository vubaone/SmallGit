import Foundation
import Darwin
import Observation

/// Cumulative counters for this process, as the kernel reports them.
///
/// Totals, not rates: the kernel counts up, and turning that into "per
/// second" needs two of these and the time between them. Kept as its own
/// type so the arithmetic can be tested without a machine to measure.
struct PerfCounters: Equatable, Sendable {
    /// User + system CPU time consumed since launch.
    var cpuNanos: UInt64 = 0
    /// Physical footprint — the number Activity Monitor shows as "Memory".
    var memoryBytes: UInt64 = 0
    var diskReadBytes: UInt64 = 0
    var diskWriteBytes: UInt64 = 0
    /// Bytes over every non-loopback interface, machine-wide. macOS has no
    /// public per-process network counter, and SmallGit's own transfers
    /// happen inside the `git` child processes anyway, so per-process would
    /// read zero during a fetch — which would be worse than honest and wide.
    var netInBytes: UInt64 = 0
    var netOutBytes: UInt64 = 0
}

extension PerfCounters {
    /// This process now, or zeroes if the kernel declines to say.
    static func current() -> PerfCounters {
        var out = PerfCounters()
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        if status == 0 {
            out.cpuNanos = usage.ri_user_time &+ usage.ri_system_time
            out.memoryBytes = usage.ri_phys_footprint
            out.diskReadBytes = usage.ri_diskio_bytesread
            out.diskWriteBytes = usage.ri_diskio_byteswritten
        }
        let network = systemNetworkBytes()
        out.netInBytes = network.received
        out.netOutBytes = network.sent
        return out
    }

    /// Interface byte counts, loopback excluded — traffic that never left the
    /// machine is not network activity in the sense anyone means here.
    private static func systemNetworkBytes() -> (received: UInt64, sent: UInt64) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
        defer { freeifaddrs(head) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            // AF_LINK is the layer that carries the counters; the AF_INET
            // entry for the same interface has no `if_data` behind it.
            guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let name = String(cString: interface.ifa_name)
            guard !name.hasPrefix("lo") else { continue }
            guard let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            received &+= UInt64(data.pointee.ifi_ibytes)
            sent &+= UInt64(data.pointee.ifi_obytes)
        }
        return (received, sent)
    }
}

/// What the badge shows: rates, plus the one number that is a level rather
/// than a rate.
struct PerfReading: Equatable, Sendable {
    /// Percent of one core, the convention Activity Monitor uses — so more
    /// than 100 is normal on a machine with more than one.
    var cpuPercent: Double = 0
    var memoryBytes: UInt64 = 0
    var diskReadPerSecond: Double = 0
    var diskWritePerSecond: Double = 0
    var netInPerSecond: Double = 0
    var netOutPerSecond: Double = 0

    init() {}

    /// The rates between two snapshots.
    ///
    /// A counter that went backwards reads as zero rather than as a rate the
    /// size of the address space: interfaces come and go, and unsigned
    /// subtraction the wrong way round would trap rather than merely lie.
    init(from previous: PerfCounters, to current: PerfCounters, elapsed: TimeInterval) {
        guard elapsed > 0 else {
            self = PerfReading()
            memoryBytes = current.memoryBytes
            return
        }
        func rate(_ before: UInt64, _ after: UInt64) -> Double {
            after > before ? Double(after - before) / elapsed : 0
        }
        let cpuDelta = current.cpuNanos > previous.cpuNanos
            ? Double(current.cpuNanos - previous.cpuNanos)
            : 0
        cpuPercent = cpuDelta / (elapsed * 1_000_000_000) * 100
        memoryBytes = current.memoryBytes
        diskReadPerSecond = rate(previous.diskReadBytes, current.diskReadBytes)
        diskWritePerSecond = rate(previous.diskWriteBytes, current.diskWriteBytes)
        netInPerSecond = rate(previous.netInBytes, current.netInBytes)
        netOutPerSecond = rate(previous.netOutBytes, current.netOutBytes)
    }
}

/// Short forms for a badge that has to fit on one line beside the status
/// text. Hand-rolled rather than `ByteCountFormatter` because that one is
/// localised — its separators and spacing move under the reader's locale,
/// which is fine for prose and awful for a column of numbers.
enum PerfFormat {
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    static func bytes(_ value: UInt64) -> String {
        scaled(Double(value), suffix: "")
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        scaled(bytesPerSecond, suffix: "/s")
    }

    private static func scaled(_ value: Double, suffix: String) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = max(0, value)
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        // Bytes are never fractional, and a decimal place stops being worth
        // its width once the number has three digits in front of it.
        let text = unit == 0 || amount >= 100
            ? String(Int(amount.rounded()))
            : String(format: "%.1f", amount)
        return text + " " + units[unit] + suffix
    }
}

/// Samples this process on a timer while the performance badge is on screen.
///
/// Nothing runs when the badge is off: the view owns the sampler and the loop
/// lives in its `task`, so a measurement tool that is not being looked at
/// costs nothing — which is the first thing to get right about one.
@MainActor
@Observable
final class PerformanceSampler {
    /// `nil` until two samples exist. Every number here except memory is a
    /// rate, and a rate needs two readings — zeroes for the first second
    /// would be showing a measurement nobody took.
    private(set) var reading: PerfReading?

    private var previous: PerfCounters?
    private var previousAt: Date?
    private let read: () -> PerfCounters
    private let clock: () -> Date

    init(
        read: @escaping () -> PerfCounters = PerfCounters.current,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.read = read
        self.clock = clock
    }

    /// A sampler that already holds a reading, for previews and tests that
    /// need a badge showing known numbers rather than this machine's.
    convenience init(reading: PerfReading) {
        self.init()
        self.reading = reading
    }

    /// Take one sample, publishing a reading once there is a previous one to
    /// measure against.
    func sample() {
        let counters = read()
        let at = clock()
        defer {
            previous = counters
            previousAt = at
        }
        guard let previous, let previousAt else { return }
        let elapsed = at.timeIntervalSince(previousAt)
        guard elapsed > 0 else { return }
        reading = PerfReading(from: previous, to: counters, elapsed: elapsed)
    }

    /// Sample until cancelled. One second is slow enough to cost nothing and
    /// fast enough that a spike is still on screen when the eye gets there.
    ///
    /// Starts from nothing every time. Switching the badge off and on again
    /// otherwise measures across the gap: an hour of elapsed time under a
    /// second's worth of counters, which reads as an idle app rather than as
    /// the "no measurement yet" it actually is.
    func run(interval: Duration = .seconds(1)) async {
        reading = nil
        previous = nil
        previousAt = nil
        sample()
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            sample()
        }
    }
}
