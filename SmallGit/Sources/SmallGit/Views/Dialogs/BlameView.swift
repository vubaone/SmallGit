import SwiftUI

/// Line-by-line authorship for a file (`git blame`). Surfaced from the
/// Files panel right-click as "Blame…". Each row shows the commit, author,
/// and date that last touched the line, alongside the source text — the
/// "who changed this line" lookup Fork / SmartGit / GitKraken all provide.
struct BlameView: View {
    @Bindable var appState: AppState
    let path: String
    @Environment(\.dismiss) private var dismiss

    @State private var lines: [GitBlameLine] = []
    @State private var loading = true
    @State private var selection: Int?
    @State private var selectedLineHistory = ""
    @State private var loadingLineHistory = false
    @State private var highlightMode = "Changes Since"

    private var fileName: String { (path as NSString).lastPathComponent }
    private var selectedLine: GitBlameLine? {
        guard let selection else { return nil }
        return lines.first { $0.lineNumber == selection }
    }

    private let hashWidth: CGFloat = 50
    private let authorWidth: CGFloat = 58
    private let lineNoWidth: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            controls

            if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 240)
            } else if lines.isEmpty {
                emptyState
            } else {
                VSplitView {
                    blameList
                        .frame(minHeight: 340)
                    lineHistoryPane
                        .frame(minHeight: 118, idealHeight: 150)
                }
            }

            footer
        }
        .padding(12)
        .frame(minWidth: 860, minHeight: 680)
        .background(Color.bgPanel)
        .task {
            lines = await appState.blame(path: path)
            loading = false
            if selection == nil { selection = lines.first?.lineNumber }
        }
        .task(id: selection) {
            await loadSelectedLineHistory()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Blame: \(fileName)").font(.title3.bold())
                Text(path)
                    .scaledFont(10, design: .monospaced)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("\(lines.count) line\(lines.count == 1 ? "" : "s")")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Text("Document")
                .scaledFont(11, weight: .semibold)
                .foregroundStyle(Color.textPrimary)

            Spacer()

            Text("Highlight:")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
            Picker("", selection: $highlightMode) {
                Text("Changes Since").tag("Changes Since")
                Text("Commit Blocks").tag("Commit Blocks")
            }
            .labelsHidden()
            .frame(width: 150)

            if let selectedLine {
                Text("Line \(selectedLine.lineNumber)")
                    .scaledFont(11, design: .monospaced)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.bgPanelHeader)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.strongBorder).frame(height: 0.5)
        }
    }

    private var blameList: some View {
        GeometryReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        row(for: line, startsBlock: startsBlock(at: index))
                            .frame(minWidth: proxy.size.width, alignment: .leading)
                            .background(rowBackground(for: line, startsBlock: startsBlock(at: index)))
                            .contentShape(Rectangle())
                            .onTapGesture { selection = line.lineNumber }
                            .help(line.summary)
                    }
                }
                .frame(minWidth: proxy.size.width, alignment: .leading)
            }
            .background(Color.bgPanel)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.strongBorder.opacity(0.7), lineWidth: 0.5)
            }
        }
    }

    private func row(for line: GitBlameLine, startsBlock: Bool) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(startsBlock ? blameHash(for: line) : "")
                    .scaledFont(11, design: .monospaced)
                    .foregroundStyle(Color.accentBlue)
                    .frame(width: hashWidth, alignment: .leading)
                Text(startsBlock ? line.author : "")
                    .scaledFont(10)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: authorWidth, alignment: .leading)
            }
            .padding(.horizontal, 4)
            .background(Color.bgInput.opacity(0.48))

            Text("\(line.lineNumber)")
                .scaledFont(10, design: .monospaced)
                .foregroundStyle(Color.textDisabled)
                .frame(width: lineNoWidth, alignment: .trailing)
                .padding(.trailing, 6)
            Text(line.content.isEmpty ? " " : line.content)
                .scaledFont(12, design: .monospaced)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, 2)
        }
        .padding(.vertical, 1)
    }

    private var lineHistoryPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("History of current line")
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(Color.textPrimary)
                if let selectedLine {
                    Text(blameHash(for: selectedLine))
                        .scaledFont(11, design: .monospaced)
                        .foregroundStyle(Color.accentBlue)
                    Text(selectedLine.author)
                        .scaledFont(11)
                        .foregroundStyle(Color.textSecondary)
                    Text(relativeDate(for: selectedLine))
                        .scaledFont(10)
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer()
                if loadingLineHistory {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.bgPanelHeader)

            ScrollView([.vertical, .horizontal]) {
                Text(historyText)
                    .scaledFont(11, design: .monospaced)
                    .foregroundStyle(Color.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color.bgPanel)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.strongBorder.opacity(0.7), lineWidth: 0.5)
        }
    }

    private var historyText: String {
        if selectedLine == nil { return "Select a line to see its history." }
        if loadingLineHistory { return "Loading…" }
        if selectedLineHistory.isEmpty { return "(no line history)" }
        return selectedLineHistory
    }

    private var footer: some View {
        HStack {
            Button("Copy Hash") {
                if let sel = selection, let line = lines.first(where: { $0.lineNumber == sel }) {
                    appState.copyToPasteboard(line.commitHash)
                }
            }
            .disabled(selection == nil)

            Spacer()

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func startsBlock(at index: Int) -> Bool {
        index == 0 || lines[index - 1].commitHash != lines[index].commitHash
    }

    private func rowBackground(for line: GitBlameLine, startsBlock: Bool) -> Color {
        if line.lineNumber == selection {
            return Color.accentColor.opacity(0.18)
        }
        if startsBlock && highlightMode == "Commit Blocks" {
            return Color.bgHover.opacity(0.55)
        }
        return .clear
    }

    private func blameHash(for line: GitBlameLine) -> String {
        let hash = String(line.shortHash.prefix(6))
        return line.isBoundary ? "^\(hash.prefix(5))" : hash
    }

    private func relativeDate(for line: GitBlameLine) -> String {
        line.date.map { DateFormatters.relative(from: $0) } ?? "—"
    }

    private func loadSelectedLineHistory() async {
        guard let requestedLine = selection else {
            selectedLineHistory = ""
            loadingLineHistory = false
            return
        }
        loadingLineHistory = true
        let history = await appState.blameLineHistory(path: path, line: requestedLine)
        guard selection == requestedLine else { return }
        selectedLineHistory = history
        loadingLineHistory = false
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "person.crop.rectangle.stack")
                .scaledFont(28, weight: .light)
                .foregroundStyle(Color.textDisabled)
            Text("No blame information")
                .foregroundStyle(Color.textSecondary)
            Text("The file may be untracked, binary, or not yet committed.")
                .scaledFont(10)
                .foregroundStyle(Color.textDisabled)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}
