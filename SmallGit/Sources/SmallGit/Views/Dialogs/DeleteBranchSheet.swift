import SwiftUI

/// Confirmation for deleting local branches — one, or a whole sidebar
/// selection of them.
///
/// The old context-menu item ran `git branch -d` straight away, so an
/// unmerged branch produced nothing but a red row in the command log with
/// git's "not fully merged" hint buried in it. This sheet asks git the same
/// question first and puts the answer on screen: merged branches get a plain
/// Delete, unmerged ones have to be armed before the force delete unlocks.
struct DeleteBranchSheet: View {
    let target: AppState.BranchDeletionTarget
    @Bindable var appState: AppState

    @Environment(\.dismiss) private var dismiss
    @State private var forceConfirmed = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    /// Set when git refuses a `-d` we expected to succeed — the sheet then
    /// shows the same force-delete path as a known-unmerged branch.
    @State private var gitRefusedAsUnmerged = false
    /// The branches git wouldn't delete on the last pass. Once a pass has
    /// run, this is what the sheet is about: the deletes that succeeded are
    /// done, and a second attempt must not ask git to repeat them.
    @State private var refused: [GitBranch]?

    private var branches: [GitBranch] { refused ?? target.branches }
    private var isSingle: Bool { branches.count == 1 }

    private func check(_ branch: GitBranch) -> BranchDeletionCheck? {
        target.checks[branch.name]
    }

    /// True when a branch needs `-D`: the pre-flight check said so, and an
    /// unchecked one doesn't count — git decides, and the sheet re-arms if it
    /// says no.
    private func needsForce(_ branch: GitBranch) -> Bool {
        check(branch).map { !$0.isFullyMerged } ?? false
    }

    /// True when the delete needs `-D`, either because the pre-flight check
    /// said so of any branch in the batch or because git said so when we
    /// tried.
    private var needsForce: Bool {
        gitRefusedAsUnmerged || branches.contains(where: needsForce)
    }

    private var canDelete: Bool {
        !isWorking && !branches.isEmpty && (!needsForce || forceConfirmed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            explanation
            if isSingle, let branch = branches.first {
                statusCard(for: branch)
            } else {
                branchList
            }

            if needsForce {
                Toggle(isOn: $forceConfirmed) {
                    Text(forceConfirmLabel)
                        .scaledFont(12)
                        .foregroundStyle(Color.textPrimary)
                }
                .toggleStyle(.checkbox)
                .disabled(isWorking)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(11)
                    .foregroundStyle(Color.diffDelText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            actions
        }
        .padding(20)
        .frame(width: 500)
        .background(Color.bgPanel)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: needsForce ? "exclamationmark.triangle.fill" : "trash")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(needsForce ? Color.orange : Color.textSecondary)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill((needsForce ? Color.orange : Color.textSecondary).opacity(0.13))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(isSingle ? "Delete Branch" : "Delete \(branches.count) Branches")
                    .font(.title3.bold())
                    .foregroundStyle(Color.textPrimary)
                if isSingle, let branch = branches.first {
                    Text(branch.name)
                        .scaledFont(12, design: .monospaced)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text(summaryLine)
                        .scaledFont(12)
                        .foregroundStyle(Color.textSecondary)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var explanation: some View {
        Text(isSingle
             ? "This removes the local branch. The commits themselves stay in the repository and remain reachable through the reflog for a while, but nothing will point at them by name."
             : "This removes these local branches. The commits themselves stay in the repository and remain reachable through the reflog for a while, but nothing will point at them by name.")
            .scaledFont(12)
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One line of arithmetic for the batch header, so the count in the title
    /// isn't the only thing the user has to go on.
    private var summaryLine: String {
        let merged = branches.filter { check($0)?.isFullyMerged == true }.count
        let unmerged = branches.filter(needsForce).count
        let unchecked = branches.count - merged - unmerged
        var parts: [String] = []
        if merged > 0 { parts.append("\(merged) already merged") }
        if unmerged > 0 { parts.append("\(unmerged) not merged anywhere") }
        if unchecked > 0 { parts.append("\(unchecked) unchecked") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Merge status

    @ViewBuilder
    private func statusCard(for branch: GitBranch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            noticeRow(
                icon: statusIcon(for: branch),
                tint: statusTint(for: branch),
                text: statusText(for: branch)
            )

            if let upstream = branch.upstream, branch.upstreamGone {
                noticeRow(
                    icon: "bolt.horizontal.circle.fill",
                    tint: Color.textSecondary,
                    text: "Its upstream \(upstream) no longer exists on the remote, so git can't use it to vouch for these commits."
                )
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(tint: statusTint(for: branch)))
    }

    /// The batch form of the status card: every branch with what deleting it
    /// costs, since a summary line can't say which of thirty is the unmerged
    /// one.
    @ViewBuilder
    private var branchList: some View {
        let rows = VStack(alignment: .leading, spacing: 6) {
            ForEach(branches) { branch in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: statusIcon(for: branch))
                        .scaledFont(11)
                        .foregroundStyle(statusTint(for: branch))
                    Text(branch.name)
                        .scaledFont(11, design: .monospaced)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(shortStatus(for: branch))
                        .scaledFont(10)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize()
                }
                .help(statusText(for: branch))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)

        // Scrolls only once the list is long enough to need it — a fixed-height
        // box would leave a batch of three floating in empty space.
        if branches.count > 8 {
            ScrollView { rows }
                .frame(height: 240)
                .background(cardBackground(tint: batchTint))
        } else {
            rows.background(cardBackground(tint: batchTint))
        }
    }

    private func cardBackground(tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(tint.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(tint.opacity(0.25), lineWidth: 0.5)
            )
    }

    /// The batch card takes the colour of its worst row: one unmerged branch
    /// in thirty is still a warning.
    private var batchTint: Color {
        needsForce ? Color.orange : Color.accentBlue
    }

    private func noticeRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .scaledFont(12)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusIcon(for branch: GitBranch) -> String {
        guard let check = check(branch), !gitRefusedAsUnmerged else {
            return "exclamationmark.triangle.fill"
        }
        return check.isFullyMerged ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func statusTint(for branch: GitBranch) -> Color {
        guard let check = check(branch), !gitRefusedAsUnmerged else { return Color.orange }
        return check.isFullyMerged ? Color.accentBlue : Color.orange
    }

    private func statusText(for branch: GitBranch) -> String {
        if gitRefusedAsUnmerged {
            return "git refused the safe delete: this branch isn't merged anywhere it can see. Deleting it now means only the reflog remembers its commits."
        }
        guard let check = check(branch) else {
            return "SmallGit couldn't work out whether this branch is merged. git will still refuse the delete if it isn't."
        }
        if let mergedInto = check.mergedInto {
            if check.isMergedElsewhere {
                return "Already merged into \(mergedInto), so nothing is lost — though \(commitCount(check.unmergedCount)) here \(check.unmergedCount == 1 ? "is" : "are") not on \(check.comparedTo)."
            }
            return "Already merged into \(mergedInto) — deleting it loses no work."
        }
        return "Not merged anywhere: \(commitCount(check.unmergedCount)) on this branch \(check.unmergedCount == 1 ? "is" : "are") not on \(check.comparedTo), and no other branch contains them."
    }

    /// Right-hand end of a row in the batch list — the same verdict as
    /// `statusText`, in the width a list can spare.
    private func shortStatus(for branch: GitBranch) -> String {
        guard let check = check(branch) else { return "not checked" }
        if let mergedInto = check.mergedInto {
            return check.isMergedElsewhere ? "merged into \(mergedInto)" : "merged"
        }
        return "\(commitCount(check.unmergedCount)) unmerged"
    }

    private var forceConfirmLabel: String {
        if isSingle, let branch = branches.first {
            guard let check = check(branch), !check.isFullyMerged, check.unmergedCount > 0 else {
                return "Delete anyway, discarding whatever isn't merged"
            }
            return "Delete anyway, discarding \(commitCount(check.unmergedCount))"
        }
        let count = branches.filter(needsForce).count
        guard count > 0 else { return "Delete anyway, discarding whatever isn't merged" }
        return "Delete anyway, discarding what isn't merged on \(count == 1 ? "1 branch" : "\(count) branches")"
    }

    private func commitCount(_ n: Int) -> String {
        n == 1 ? "1 commit" : "\(n) commits"
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Cancel", role: .cancel) {
                appState.cancelBranchDeletion()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isWorking)

            Spacer()

            if needsForce {
                Button(isSingle ? "Force Delete" : "Force Delete \(branches.count) Branches",
                       role: .destructive) { perform(force: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canDelete)
            } else {
                Button(isSingle ? "Delete" : "Delete \(branches.count) Branches") {
                    perform(force: false)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canDelete)
            }
        }
    }

    private func perform(force: Bool) {
        isWorking = true
        errorMessage = nil
        let attempt = branches
        Task {
            let report = await appState.confirmBranchDeletion(attempt, force: force)
            isWorking = false
            if report.isComplete {
                dismiss()
                return
            }
            // Narrow the sheet to what git wouldn't take. Anything it did
            // delete is gone, and re-arming the whole batch would ask for
            // those again.
            refused = report.refused
            // The pre-flight check and git disagreed. Trust git, and re-arm
            // the confirmation rather than silently retrying.
            gitRefusedAsUnmerged = !report.unmerged.isEmpty
            forceConfirmed = false
            errorMessage = failureMessage(report)
        }
    }

    /// What to put in the error line. The unmerged case says nothing here: it
    /// is already the whole point of the re-armed force toggle below.
    private func failureMessage(_ report: AppState.BranchDeletionReport) -> String? {
        var lines: [String] = []
        if !report.deleted.isEmpty {
            lines.append("Deleted \(report.deleted.count) of \(report.attempted) — \(report.refused.count) left.")
        }
        for failure in report.failed {
            lines.append("\(failure.branch.name): \(failure.message)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
