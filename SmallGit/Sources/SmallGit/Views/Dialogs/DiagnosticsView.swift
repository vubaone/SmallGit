import SwiftUI
import AppKit

/// Settings › Diagnostics — reads back what `LogStore` has recorded.
///
/// Three views of the same records, in the order you actually want them when
/// something is wrong:
///
/// - **Findings** answers "is anything obviously broken?" without reading
///   anything. Most sessions have none, and that is a useful answer too.
/// - **Summary** is where a real investigation happens: per-operation totals,
///   sortable, so "what is slow" and "what runs too often" are each one click.
/// - **Records** is the raw stream, for when you already know what you are
///   looking for.
struct DiagnosticsView: View {
    @Bindable var appState: AppState

    @State private var records: [LogRecord] = []
    @State private var summary: LogSummaryResult = .empty
    @State private var findings: [LogFinding] = []
    @State private var isLoading = false
    @State private var mode: Mode = .findings
    @State private var categoryFilter: LogCategory?
    @State private var search = ""
    @State private var summarySort: SummarySort = .totalTime

    /// An explicit picker rather than `Table`'s clickable headers.
    ///
    /// `sortOrder:` wants `KeyPathComparator`, whose initialiser requires a
    /// `Sendable` key path — which Swift 5 language mode doesn't provide, so
    /// it warns under this package's strict-concurrency setting. Naming the
    /// orderings turns out to read better anyway: these are the questions
    /// being asked, and "Calls/min" says what it finds more plainly than a
    /// column header does.
    private enum SummarySort: String, CaseIterable, Identifiable {
        case totalTime = "Total time"
        case rate = "Calls/min"
        case slowest = "Slowest call"
        case count = "Call count"
        case errors = "Errors"

        var id: String { rawValue }
    }

    private enum Mode: String, CaseIterable, Identifiable {
        case findings = "Findings"
        case summary = "Summary"
        case records = "Records"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls
            Divider()
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .task { await reload() }
    }

    // MARK: - Header

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Record diagnostics", isOn: Binding(
                get: { appState.appConfig.diagnosticsLoggingEnabled },
                set: { newValue in
                    appState.appConfig.diagnosticsLoggingEnabled = newValue
                    Log.store.setEnabled(newValue)
                    // Saved, or the choice lasts until the next launch and
                    // then quietly goes back to recording — which is the one
                    // way a switch like this can be worse than not having it.
                    Task { await appState.saveAppConfig() }
                }
            ))
            .help("Off records nothing: no file is written and nothing is held in memory waiting to be.")

            Toggle("Show performance badge", isOn: Binding(
                get: { appState.appConfig.perfBadgeEnabled },
                set: { newValue in
                    appState.appConfig.perfBadgeEnabled = newValue
                    Task { await appState.saveAppConfig() }
                }
            ))
            .help(PerfBadge.explanation)

            Text(statusLine)
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusLine: String {
        guard !isLoading else { return "Reading the log…" }
        let store = Log.store
        let size = byteText(store.totalSizeBytes)
        let limit = byteText(store.sizeLimitBytes)
        guard summary.recordCount > 0 else {
            return "\(size) of \(limit) on disk. No records yet — use the app for a while, then Refresh."
        }
        // Active time, not first-to-last: the log survives across launches, and
        // "408 records over 9 hours" describes a laptop that was asleep, not an
        // app that was working.
        let active = LogDiagnosis.format(minutes: summary.activeSeconds / 60)
        let sessions = summary.sessionCount == 1 ? "1 session" : "\(summary.sessionCount) sessions"
        return "\(summary.recordCount) records · \(active) of activity across \(sessions) · \(size) of \(limit) on disk"
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch mode {
            case .findings: findingsList
            case .summary:  summaryTable
            case .records:  recordsSection
            }
        }
    }

    @ViewBuilder
    private var findingsList: some View {
        if summary.recordCount == 0 {
            placeholder(
                icon: "waveform.path.ecg",
                title: "Nothing recorded yet",
                message: "Diagnostics start empty on each install. Work in the app — open a repo, fetch, browse history — then come back and press Refresh."
            )
        } else if findings.isEmpty {
            placeholder(
                icon: "checkmark.seal",
                title: "No problems found",
                message: "Across \(summary.recordCount) operations: nothing failed, nothing is running on a loop, and no remote call was unusually slow. The Summary tab has the raw numbers."
            )
        } else {
            List(findings) { finding in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: finding.severity == .warning
                          ? "exclamationmark.triangle.fill"
                          : "info.circle.fill")
                        .foregroundStyle(finding.severity == .warning ? Color.orange : Color.accentBlue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finding.title).scaledFont(12, weight: .semibold)
                        Text(finding.detail)
                            .scaledFont(11)
                            .foregroundStyle(Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private var summaryTable: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("Sort by").scaledFont(11).foregroundStyle(Color.textSecondary)
                Picker("", selection: $summarySort) {
                    ForEach(SummarySort.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
                Spacer()
                Text("\(summary.rows.count) operations")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
            }

            Table(sortedRows) {
                TableColumn("Operation") { row in
                    Text(row.operation).scaledFont(11, design: .monospaced)
                }
                TableColumn("Where") { row in
                    Text(row.category.label).scaledFont(11)
                }
                .width(60)
                TableColumn("Count") { row in
                    Text("\(row.count)").scaledFont(11).monospacedDigit()
                }
                .width(50)
                TableColumn("/min") { row in
                    Text(row.perMinute.map { String(format: "%.1f", $0) } ?? "—")
                        .scaledFont(11).monospacedDigit()
                }
                .width(50)
                TableColumn("Avg") { row in
                    Text(row.totalMs > 0 ? LogDiagnosis.format(ms: row.averageMs) : "—")
                        .scaledFont(11).monospacedDigit()
                }
                .width(66)
                TableColumn("Max") { row in
                    Text(row.maxMs > 0 ? LogDiagnosis.format(ms: row.maxMs) : "—")
                        .scaledFont(11).monospacedDigit()
                }
                .width(66)
                TableColumn("Total") { row in
                    Text(row.totalMs > 0 ? LogDiagnosis.format(ms: row.totalMs) : "—")
                        .scaledFont(11).monospacedDigit()
                }
                .width(70)
                TableColumn("Errors") { row in
                    Text(row.failures == 0 ? "—" : "\(row.failures)")
                        .scaledFont(11)
                        .monospacedDigit()
                        .foregroundStyle(row.failures == 0 ? Color.textSecondary : Color.orange)
                }
                .width(50)
            }
        }
    }

    private var sortedRows: [LogSummaryRow] {
        switch summarySort {
        case .totalTime: return summary.rows.sorted { $0.totalMs > $1.totalMs }
        case .rate:      return summary.rows.sorted { ($0.perMinute ?? 0) > ($1.perMinute ?? 0) }
        case .slowest:   return summary.rows.sorted { $0.maxMs > $1.maxMs }
        case .count:     return summary.rows.sorted { $0.count > $1.count }
        case .errors:    return summary.rows.sorted { $0.failures > $1.failures }
        }
    }

    private var recordsSection: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: $categoryFilter) {
                    Text("All").tag(LogCategory?.none)
                    ForEach(LogCategory.allCases, id: \.self) { category in
                        Text(category.label).tag(LogCategory?.some(category))
                    }
                }
                .labelsHidden()
                .frame(width: 110)

                TextField("Filter by operation or detail", text: $search)
                    .textFieldStyle(.roundedBorder)

                Text("\(filteredRecords.count)")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
                    .monospacedDigit()
            }

            Table(filteredRecords) {
                TableColumn("Time") { Text(timeText($0.record.at)).scaledFont(10, design: .monospaced) }
                    .width(84)
                TableColumn("Operation") { Text($0.record.operation).scaledFont(10, design: .monospaced) }
                    .width(110)
                TableColumn("ms") {
                    Text($0.record.ms.map { LogDiagnosis.format(ms: $0) } ?? "—")
                        .scaledFont(10).monospacedDigit()
                }
                .width(64)
                TableColumn("Size") {
                    Text($0.record.bytes.map(byteText) ?? "—").scaledFont(10).monospacedDigit()
                }
                .width(64)
                TableColumn("Result") { row in
                    Text(row.record.outcome.label)
                        .scaledFont(10)
                        .foregroundStyle(row.record.outcome.isFailure ? Color.orange : Color.textSecondary)
                }
                .width(64)
                TableColumn("Detail") { row in
                    Text(row.record.message.map { "\(row.record.detail) — \($0)" } ?? row.record.detail)
                        .scaledFont(10, design: .monospaced)
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
    }

    private func placeholder(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .scaledFont(26, weight: .light)
                .foregroundStyle(Color.textDisabled)
            Text(title).scaledFont(12, weight: .semibold)
            Text(message)
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            // Manual rather than on a timer: refreshing re-reads and re-decodes
            // the whole log, and a diagnostics screen that generates a burst of
            // disk I/O every two seconds would be measuring itself.
            Button("Refresh") { Task { await reload() } }
                .disabled(isLoading)

            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([Log.store.currentURL])
            }

            Button("Copy") { copyToPasteboard() }
                .disabled(records.isEmpty)

            Spacer()

            Button("Clear Log", role: .destructive) {
                Log.store.clear()
                Task { await reload() }
            }
            .disabled(records.isEmpty)
        }
    }

    // MARK: - Data

    private func reload() async {
        isLoading = true
        // Off the main actor: reading is up to 5 MB of file plus a JSON decode
        // per line, which is well past what a UI thread should be doing.
        let loaded = await Task.detached(priority: .userInitiated) {
            Log.store.read()
        }.value
        let computed = LogSummary.summarize(loaded)
        records = loaded
        summary = computed
        findings = LogDiagnosis.findings(computed)
        isLoading = false
    }

    /// The viewer supplies identity: `LogRecord` deliberately carries none,
    /// so position in the file is what distinguishes two identical records.
    private struct IndexedRecord: Identifiable {
        let id: Int
        let record: LogRecord
    }

    private var filteredRecords: [IndexedRecord] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [IndexedRecord] = []
        // Newest first — the opposite of the file's order, because the reason
        // anyone opens this is something that just happened.
        for (index, record) in records.enumerated().reversed() {
            if let categoryFilter, record.category != categoryFilter { continue }
            if !needle.isEmpty {
                let haystack = "\(record.operation) \(record.detail) \(record.message ?? "")".lowercased()
                guard haystack.contains(needle) else { continue }
            }
            out.append(IndexedRecord(id: index, record: record))
        }
        return out
    }

    private func copyToPasteboard() {
        let text = filteredRecords.reversed().map { entry -> String in
            let record = entry.record
            let parts = [
                timeText(record.at),
                record.category.label,
                record.operation,
                record.ms.map { LogDiagnosis.format(ms: $0) } ?? "",
                record.bytes.map(byteText) ?? "",
                record.outcome.label,
                record.detail,
                record.message ?? ""
            ]
            return parts.filter { !$0.isEmpty }.joined(separator: "\t")
        }.joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Formatting

    /// `.memory`, not `.file`: the cap is defined in binary megabytes, and the
    /// decimal formatter renders that 5 MB budget as "5.2 MB" — which reads
    /// like the limit is being exceeded at the exact moment it is being
    /// enforced.
    private func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private func timeText(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
