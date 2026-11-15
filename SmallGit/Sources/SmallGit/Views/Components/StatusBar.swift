import SwiftUI

/// Bottom-most status strip: shows current operation status on the left and
/// quick repo metrics on the right.
struct StatusBar: View {
    let statusText: String
    let changedFileCount: Int
    let cursorInfo: String?
    let isWorking: Bool
    /// The sampler behind the performance badge, or `nil` when the badge is
    /// switched off in Settings › Diagnostics.
    ///
    /// The sampler, not its reading. Read here, a fresh sample invalidates
    /// this strip and nothing else; read where the bar is *built* — in the
    /// window's own body — it re-evaluated the whole window, every panel in
    /// it, once a second for four numbers in the corner. Still sampled
    /// outside rather than here: the bar redraws on every status change, and
    /// a measurement taken per redraw would be measuring the redraw.
    var perfSampler: PerformanceSampler? = nil

    var body: some View {
        HStack(spacing: 10) {
            if isWorking {
                ProgressView()
                    .accessibilityIdentifier("status.progress")
                    .controlSize(.small)
                    .tint(.white)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
            }
            Text(statusText)
                .accessibilityIdentifier("status.message")
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if let reading = perfSampler?.reading {
                PerfBadge(reading: reading)
                StatusMetricDivider()
            }
            Text("\(changedFileCount) Files")
                .accessibilityIdentifier("status.fileCount")
            if let cursorInfo {
                Text(cursorInfo)
                    .accessibilityIdentifier("status.cursor")
            }
        }
        .scaledFont(11)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Color.accentBlue)
    }
}

#Preview("idle") {
    StatusBar(statusText: "Ready", changedFileCount: 3, cursorInfo: "201:1", isWorking: false)
        .preferredColorScheme(.dark)
}

#Preview("working") {
    StatusBar(statusText: "Pull…", changedFileCount: 3, cursorInfo: nil, isWorking: true)
        .preferredColorScheme(.dark)
}
