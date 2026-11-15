import SwiftUI

/// The performance badge: what this process is costing, at a glance.
///
/// It lives in the status bar rather than floating over the content, because
/// a debugging read-out that covers the thing being debugged is a poor
/// trade — and because the status bar is already the strip that answers
/// "what is the app doing right now".
///
/// Arrows are in/out. Numbers are monospaced so a rate that changes every
/// second does not shuffle the row beside it.
struct PerfBadge: View {
    let reading: PerfReading
    @Environment(\.uiScale) private var uiScale

    /// Reserved widths keep every label, arrow and following status item in
    /// place while the sampled values change. Values are right-aligned so
    /// their unit stays anchored and only the leading digits move.
    private enum ValueWidth {
        static let cpu: CGFloat = 40
        static let memory: CGFloat = 62
        static let rate: CGFloat = 72
    }

    var body: some View {
        HStack(spacing: 8 * uiScale) {
            metric("CPU", PerfFormat.percent(reading.cpuPercent), width: ValueWidth.cpu)
            StatusMetricDivider()
            metric("MEM", PerfFormat.bytes(reading.memoryBytes), width: ValueWidth.memory)
            StatusMetricDivider()
            transferMetric(
                "DISK",
                incoming: PerfFormat.rate(reading.diskReadPerSecond),
                outgoing: PerfFormat.rate(reading.diskWritePerSecond)
            )
            StatusMetricDivider()
            transferMetric(
                "NET",
                incoming: PerfFormat.rate(reading.netInPerSecond),
                outgoing: PerfFormat.rate(reading.netOutPerSecond)
            )
        }
        .fixedSize(horizontal: true, vertical: false)
        .help(Self.explanation)
    }

    private func metric(_ label: String, _ value: String, width: CGFloat) -> some View {
        HStack(spacing: 4 * uiScale) {
            metricLabel(label)
            fixedValue(value, width: width)
        }
    }

    private func transferMetric(
        _ label: String,
        incoming: String,
        outgoing: String
    ) -> some View {
        HStack(spacing: 4 * uiScale) {
            metricLabel(label)
            directionalValue(incoming, "↓")
            directionalValue(outgoing, "↑")
        }
    }

    private func directionalValue(_ value: String, _ direction: String) -> some View {
        HStack(spacing: 2 * uiScale) {
            fixedValue(value, width: ValueWidth.rate)
            Text(direction)
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private func metricLabel(_ label: String) -> some View {
        Text(label)
            .foregroundStyle(.white.opacity(0.65))
    }

    private func fixedValue(_ value: String, width: CGFloat) -> some View {
        Text(value)
            .fontDesign(.monospaced)
            .foregroundStyle(.white)
            .frame(width: width * uiScale, alignment: .trailing)
    }

    /// Said once, on hover, because two of these four numbers mean something
    /// slightly different from what their labels suggest — and a number whose
    /// scope you have guessed at is not a measurement.
    static let explanation = """
    CPU and memory are SmallGit's own, not the git processes it spawns. \
    CPU is a percentage of one core, so more than 100% is normal on a machine \
    with more than one. Disk is this process's reads and writes. Network is \
    machine-wide: macOS has no per-process counter, and SmallGit's transfers \
    happen inside git anyway.
    """
}

/// Quiet visual boundary shared by the live performance metrics and the
/// trailing changed-file count in the status bar.
struct StatusMetricDivider: View {
    var body: some View {
        Text("|")
            .fontDesign(.monospaced)
            .foregroundStyle(.white.opacity(0.38))
            .accessibilityHidden(true)
    }
}

#Preview("badge") {
    var reading = PerfReading()
    reading.cpuPercent = 12.4
    reading.memoryBytes = 148 * 1024 * 1024
    reading.diskReadPerSecond = 1_258_291
    reading.netInPerSecond = 348_160
    reading.netOutPerSecond = 12_288
    return StatusBar(
        statusText: "Ready",
        changedFileCount: 3,
        cursorInfo: nil,
        isWorking: false,
        perfSampler: PerformanceSampler(reading: reading)
    )
    .preferredColorScheme(.dark)
}
