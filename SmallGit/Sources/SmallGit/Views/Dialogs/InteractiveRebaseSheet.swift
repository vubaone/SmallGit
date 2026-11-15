import SwiftUI

/// The "what should this rebase do" planner. Surfaces every commit between
/// the base and HEAD, lets the user reorder them and pick a per-row action
/// (pick / squash / fixup / drop), and rewrite the message of any commit
/// the plan produces. When the user starts the rebase the resulting todo is
/// handed back to `AppState.runInteractiveRebase`.
struct InteractiveRebaseSheet: View {
    let target: InteractiveRebaseTarget
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var todo: [RebaseTodo]
    @State private var messageDraft: RebaseMessageDraft?
    /// Full messages fetched for the editor so far, keyed by hash.
    @State private var fullMessages: [String: String] = [:]

    init(target: InteractiveRebaseTarget, appState: AppState) {
        self.target = target
        self.appState = appState
        self._todo = State(initialValue: target.initialTodo)
    }

    private var validationError: String? { todo.validationError }

    /// Whether the plan is still (or again) the untouched all-pick plan —
    /// which is what decides the direction of the reset button below.
    private var allPicked: Bool { !todo.isEmpty && todo.allSatisfy { $0.action == .pick } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Rebase Interactively").font(.title3.bold())
                Spacer()
                Text("onto \(target.baseDisplay)")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
            }

            Text("Drag rows to reorder. The first row is the oldest commit and runs first. Squash folds a commit into the pick above it and keeps both messages; Fixup folds it in and discards its message. Right-click a row to edit the message.")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Said out loud, because the alternative is a user counting rows
            // and wondering where their first three commits went. They are not
            // listed: there is no decision to make about a commit the base
            // already has, and listing them is what made people drop them by
            // hand before git was asked.
            if !target.alreadyOnBase.isEmpty {
                let count = target.alreadyOnBase.count
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(Color.textSecondary)
                    Text("\(count) commit\(count == 1 ? " is" : "s are") already on \(target.baseDisplay) and will be skipped")
                        .scaledFont(11)
                        .foregroundStyle(Color.textSecondary)
                }
                .help(target.alreadyOnBase
                    .map { "\($0.shortHash) \($0.subject)" }
                    .joined(separator: "\n"))
            }

            if todo.isEmpty {
                emptyState
            } else {
                List {
                    ForEach($todo) { $row in
                        let index = todo.firstIndex { $0.id == row.id } ?? 0
                        let owner = todo.messageOwner(of: index)
                        RebaseTodoRow(
                            row: $row,
                            target: todo.squashTarget(of: index).map { todo[$0] },
                            foldedCount: todo.squashMembers(of: index).count,
                            needsReview: todo.needsMessageReview(index),
                            onEditMessage: owner.map { owner in { editMessage(of: owner) } },
                            onRestoreMessage: owner.flatMap { owner in
                                todo[owner].message == nil ? nil : { todo[owner].message = nil }
                            }
                        )
                    }
                    .onMove { indices, newOffset in
                        todo.move(fromOffsets: indices, toOffset: newOffset)
                    }
                }
                .frame(minHeight: 260)
            }

            if let error = validationError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .scaledFont(11)
                        .foregroundStyle(Color.textPrimary)
                }
            }

            HStack {
                // One button, both directions. Sitting there greyed out once
                // every row says pick — which is the state the sheet opens in —
                // it was a dead control exactly when the user first looked at
                // it. Flipped, it is the way to clear the board and pick back
                // the few commits you actually want.
                Button(allPicked ? "Reset to Pick None" : "Reset to Pick All") {
                    let action: RebaseAction = allPicked ? .drop : .pick
                    for index in todo.indices { todo[index].action = action }
                }
                .scaledFont(11)
                .disabled(todo.isEmpty)

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Rebase") {
                    let plan = todo
                    let onto = target.base
                    let label = target.baseDisplay
                    dismiss()
                    Task {
                        await appState.runInteractiveRebase(plan: plan, onto: onto, display: label)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validationError != nil)
            }
        }
        .padding(18)
        .frame(minWidth: 620, minHeight: 440)
        .background(Color.bgPanel)
        .sheet(item: $messageDraft) { draft in
            RebaseMessageEditor(draft: draft) { saveMessage(draft, text: $0) }
        }
    }

    /// Opens the editor on the message the pick at `index` would end up
    /// with: the user's own if they wrote one, otherwise what git would make
    /// of it — its message, then each squashed commit's below it. Fixup
    /// messages are left out, as git leaves them out.
    private func editMessage(of index: Int) {
        let head = todo[index]
        let squashed = todo.squashMembers(of: index)
            .map { todo[$0] }
            .filter { $0.action == .squash }
        let contributors = [head] + squashed
        let folded = todo.squashMembers(of: index).count
        Task {
            let missing = contributors.map(\.hash).filter { fullMessages[$0] == nil }
            if !missing.isEmpty {
                fullMessages.merge(await appState.fullCommitMessages(missing)) { _, new in new }
            }
            let original = contributors
                .map { fullMessages[$0.hash] ?? $0.subject }
                .joined(separator: "\n\n")
            messageDraft = RebaseMessageDraft(
                id: head.id,
                shortHash: head.shortHash,
                foldedCount: folded,
                original: original,
                text: head.message ?? original
            )
        }
    }

    private func saveMessage(_ draft: RebaseMessageDraft, text: String) {
        guard let index = todo.firstIndex(where: { $0.id == draft.id }) else { return }
        let unchanged = text.trimmingCharacters(in: .whitespacesAndNewlines)
            == draft.original.trimmingCharacters(in: .whitespacesAndNewlines)
        // An untouched message on a lone pick is no change at all — an amend
        // for it would only cost a rewrite. One that takes a squash is kept
        // even unchanged: the user looked and chose it, and the row stops
        // asking.
        let takesSquash = todo.squashMembers(of: index).contains { todo[$0].action == .squash }
        todo[index].message = unchanged && !takesSquash ? nil : text
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .scaledFont(22)
                .foregroundStyle(Color.textSecondary)
            Text("Nothing to rebase")
                .scaledFont(13)
            Text("The current branch has no commits ahead of \(target.baseDisplay).")
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

/// Row UI for one commit in the rebase plan. Action picker on the left,
/// short hash + subject on the right, drag handle on macOS comes free
/// from List's onMove.
///
/// A squash or fixup row points at the pick it folds into, by an arrow and
/// that pick's hash, because "the commit above" stops meaning one row up as
/// soon as there is a drop or a second squash in between. The pick taking a
/// squash is tinted until its message has been looked at.
private struct RebaseTodoRow: View {
    @Binding var row: RebaseTodo
    /// The pick this row folds into, for a squash or fixup.
    let target: RebaseTodo?
    /// How many rows fold into this one, for a pick.
    let foldedCount: Int
    let needsReview: Bool
    /// Nil for a row whose message nothing would use — a drop, or a squash
    /// with nothing above to fold into.
    let onEditMessage: (() -> Void)?
    /// Nil when the commit still has the message git would give it.
    let onRestoreMessage: (() -> Void)?

    private var isFolded: Bool { row.action == .squash || row.action == .fixup }

    private var foldTint: Color {
        row.action == .squash ? Color.graphOrange : Color.textSecondary
    }

    /// The pick's subject as the user rewrote it; the commit's own otherwise.
    private var displayedSubject: String {
        guard row.action == .pick, let message = row.message else { return row.subject }
        return message.split(whereSeparator: \.isNewline).first.map(String.init) ?? row.subject
    }

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $row.action) {
                ForEach(RebaseAction.allCases, id: \.self) { action in
                    Text(action.displayName).tag(action)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 90)

            Text(row.shortHash)
                .scaledFont(11, design: .monospaced)
                .foregroundStyle(row.action == .drop ? Color.textDisabled : Color.textSecondary)
                .frame(width: 64, alignment: .leading)

            if isFolded {
                Image(systemName: "arrow.turn.left.up")
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(foldTint)
            }

            if row.action == .pick, row.message != nil {
                Image(systemName: "pencil")
                    .scaledFont(11)
                    .foregroundStyle(Color.accentBlue)
                    .help("Message edited — was: \(row.subject)")
            }

            Text(displayedSubject)
                .scaledFont(12)
                .lineLimit(1)
                .strikethrough(row.action == .drop, color: Color.textDisabled)
                .foregroundStyle(
                    row.action == .drop ? Color.textDisabled
                        : isFolded ? Color.textSecondary : Color.textPrimary
                )

            Spacer(minLength: 8)

            if isFolded, let target {
                Text("into \(target.shortHash)")
                    .scaledFont(11, design: .monospaced)
                    .foregroundStyle(foldTint)
                    .help("Folds into \(target.shortHash) \(target.subject)")
            } else if needsReview, let onEditMessage {
                Button(action: onEditMessage) {
                    Label("Edit Message", systemImage: "pencil")
                        .scaledFont(11)
                }
                .buttonStyle(.borderless)
                .help("\(foldedCount) commit\(foldedCount == 1 ? "" : "s") fold into this one. Their messages would just be stacked one after another.")
            } else if foldedCount > 0 {
                Text("+\(foldedCount)")
                    .scaledFont(11)
                    .foregroundStyle(Color.textSecondary)
                    .help("\(foldedCount) commit\(foldedCount == 1 ? "" : "s") fold into this one")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .listRowBackground(needsReview ? Color.graphYellow.opacity(0.18) : nil)
        .contextMenu {
            Button(isFolded ? "Edit Message of \(target?.shortHash ?? "Target")…" : "Edit Message…") {
                onEditMessage?()
            }
            .disabled(onEditMessage == nil)
            if let onRestoreMessage {
                Button("Restore Original Message", action: onRestoreMessage)
            }
            Divider()
            ForEach(RebaseAction.allCases, id: \.self) { action in
                Button(action.displayName) { row.action = action }
                    .disabled(row.action == action)
            }
        }
    }
}

/// What the message editor is working on: the pick whose resulting commit
/// gets the message, and the message git would have given it.
private struct RebaseMessageDraft: Identifiable {
    /// The pick row's id, so the save finds it even after a reorder.
    let id: String
    let shortHash: String
    let foldedCount: Int
    let original: String
    let text: String
}

private struct RebaseMessageEditor: View {
    let draft: RebaseMessageDraft
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(draft: RebaseMessageDraft, onSave: @escaping (String) -> Void) {
        self.draft = draft
        self.onSave = onSave
        self._text = State(initialValue: draft.text)
    }

    private var note: String {
        switch draft.foldedCount {
        case 0:
            return "The new message for \(draft.shortHash). It is applied when the rebase runs."
        case 1:
            return "The message for \(draft.shortHash) and the commit folded into it. The squashed message is stacked below — trim them into one."
        default:
            return "The message for \(draft.shortHash) and the \(draft.foldedCount) commits folded into it. Squashed messages are stacked below — trim them into one."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Commit Message").font(.title3.bold())
            Text(note)
                .scaledFont(11)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .scaledFont(12, design: .monospaced)
                .frame(minHeight: 200)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.textDisabled.opacity(0.4), lineWidth: 0.5)
                )

            HStack {
                Button("Use Original") { text = draft.original }
                    .scaledFont(11)
                    .disabled(text == draft.original)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(minWidth: 520, minHeight: 360)
        .background(Color.bgPanel)
    }
}
