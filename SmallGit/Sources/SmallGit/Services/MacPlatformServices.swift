import AppKit
import Foundation

@MainActor
struct MacPlatformServices: PlatformServices {
    func pickRepositoryFolders() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Repositories"
        return panel.runModal() == .OK ? panel.urls : []
    }

    func confirmWarning(title: String, message: String, primaryButton: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: primaryButton)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func resolvePushRejection(branch: String, remote: String) -> PushRejectionChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(remote)” has commits you don't have"
        alert.informativeText = """
        The push to \(branch) was rejected because \(remote) already has \
        commits that aren't in your local branch.

        • Pull & Push brings those commits in (rebasing your work on top), \
        then pushes — nothing is lost.
        • Force Push overwrites \(remote) with your local branch and can \
        discard commits other people pushed.
        """
        alert.addButton(withTitle: "Pull & Push")
        alert.addButton(withTitle: "Force Push")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .pullThenPush
        case .alertSecondButtonReturn: return .forcePush
        default:                       return .cancel
        }
    }

    func resolveBehindCheckout(branch: String, upstream: String, behind: Int) -> BehindCheckoutChoice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(upstream) is ahead of \(branch)"
        alert.informativeText = """
        At the last fetch \(upstream) had \(behind) commit\(behind == 1 ? "" : "s") \
        that \(branch) doesn't.

        • Check Out & Fast-Forward fetches, moves \(branch) up to \(upstream), \
        then checks it out.
        • Check Out Only switches to \(branch) as it is.
        """
        alert.addButton(withTitle: "Check Out & Fast-Forward")
        alert.addButton(withTitle: "Check Out Only")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .checkOutAndFastForward
        case .alertSecondButtonReturn: return .checkOutOnly
        default:                       return .cancel
        }
    }

    func resolveDivergedBranch(branch: String, upstream: String, ahead: Int, behind: Int) -> DivergedBranchChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Cannot fast-forward \(branch)"
        alert.informativeText = """
        \(branch) has \(ahead) local commit\(ahead == 1 ? "" : "s") missing from \(upstream), \
        and \(upstream) has \(behind) incoming commit\(behind == 1 ? "" : "s"). The branches have diverged.

        • Check Out & Rebase puts the local commits after the incoming commits, giving them new hashes.
        • Check Out & Merge keeps both histories and creates a merge commit.

        Both options switch to \(branch) and leave it checked out for review. \
        If conflicts occur, resolve them and Continue, or Abort.
        """
        alert.addButton(withTitle: "Check Out & Rebase")
        alert.addButton(withTitle: "Check Out & Merge")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .rebase
        case .alertSecondButtonReturn: return .merge
        default: return .cancel
        }
    }

    func resolveRewrittenBaseRebase(
        onto: String,
        staleSubjects: [String],
        ownCount: Int
    ) -> RewrittenRebaseChoice {
        let shown = 5
        var list = staleSubjects.prefix(shown).map { "• \($0)" }.joined(separator: "\n")
        if staleSubjects.count > shown {
            list += "\n…and \(staleSubjects.count - shown) more"
        }
        let own = "\(ownCount) commit\(ownCount == 1 ? "" : "s")"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(onto) was rewritten since your branch was made from it"
        alert.informativeText = """
        Your branch still carries \(staleSubjects.count) commit\(staleSubjects.count == 1 ? "" : "s") \
        from the old \(onto), which now has them under new hashes:

        \(list)

        • Rebase My \(own) replays only what you added on top.
        • Rebase Everything replays those old commits too — expect duplicates or conflicts.
        """
        alert.addButton(withTitle: "Rebase My \(ownCount) Commit\(ownCount == 1 ? "" : "s")")
        alert.addButton(withTitle: "Rebase Everything")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .ownOnly
        case .alertSecondButtonReturn: return .all
        default:                       return .cancel
        }
    }

    func resolveMerge(branch: String, into current: String, canFastForward: Bool) -> MergeChoice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Merge \(branch) into \(current)?"
        var lines: [String] = []
        if canFastForward {
            lines.append("• Fast-Forward moves \(current) up to \(branch) — no merge commit.")
        }
        lines.append("• Create Merge-Commit merges and commits in one go.")
        lines.append(
            "• Merge to Working Tree merges but stops before committing, so the result " +
            "can be built and checked first. Commit it when ready, or Abort to undo the merge."
        )
        alert.informativeText = lines.joined(separator: "\n")

        var choices: [MergeChoice] = []
        if canFastForward {
            alert.addButton(withTitle: "Fast-Forward")
            choices.append(.fastForward)
        }
        alert.addButton(withTitle: "Create Merge-Commit")
        choices.append(.mergeCommit)
        alert.addButton(withTitle: "Merge to Working Tree")
        choices.append(.workingTree)
        alert.addButton(withTitle: "Cancel")

        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(index) ? choices[index] : .cancel
    }

    func resolveRevert(commit: String, canCommit: Bool) -> RevertChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Revert this commit?"
        var lines = [commit, ""]
        if canCommit {
            lines.append("• Revert & Commit reverses the changes and creates a new commit.")
        } else {
            lines.append("There are already staged changes. Commit or unstage them before using Revert & Commit.")
        }
        lines.append("• Revert reverses the changes in the working tree and index without committing, so you can review and commit them later.")
        alert.informativeText = lines.joined(separator: "\n")

        var choices: [RevertChoice] = []
        if canCommit {
            alert.addButton(withTitle: "Revert & Commit")
            choices.append(.commit)
        }
        alert.addButton(withTitle: "Revert")
        choices.append(.workingTree)
        alert.addButton(withTitle: "Cancel")

        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(index) ? choices[index] : .cancel
    }

    func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.selectFile(
                nil,
                inFileViewerRootedAtPath: url.deletingLastPathComponent().path
            )
        }
    }

    func openInFinder(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func openInTerminal(path: String) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func openInEditor(path: String, appPath: String?, bundleIDs: [String]) {
        let url = URL(fileURLWithPath: path)
        let picked = appPath.flatMap {
            FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil
        }
        let installed = bundleIDs.lazy.compactMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }.first
        guard let appURL = picked ?? installed else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
