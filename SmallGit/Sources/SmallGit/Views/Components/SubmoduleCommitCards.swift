import SwiftUI

/// The two ends of a submodule's pointer change, side by side: what this
/// repository records on the left, what is checked out on the right.
///
/// The shape SmartGit uses for a submodule in its diff panel, and the right
/// one — a moved pointer is not a text diff, it is two commits, and the
/// first question about it is which two. The log *between* them is a
/// separate question, and the submodule's own Log window is where it is
/// answered — which is what the button between them opens.
struct SubmoduleCommitCards: View {
    let change: SubmoduleChange
    /// Opens the submodule's own Log window.
    var openLog: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            card(
                caption: "Recorded by this repository",
                sha: change.recorded,
                commit: change.recordedCommit
            )

            VStack(spacing: 6) {
                Spacer(minLength: 0)
                if let openLog {
                    Button("Open Log", action: openLog)
                        .help("The submodule's own history, in the Log window")
                }
                Spacer(minLength: 0)
            }
            .frame(width: 110)

            card(
                caption: change.pointerIsUnchanged ? "Checked out (the same)" : "Checked out",
                sha: change.current ?? change.recorded,
                commit: change.currentCommit
            )
        }
        .padding(12)
    }

    private func card(caption: String, sha: String, commit: GitCommit?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caption.uppercased())
                .scaledFont(9, weight: .medium)
                .foregroundStyle(Color.textSecondary)

            HStack(alignment: .top, spacing: 10) {
                initialsBadge(for: commit)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Commit")
                            .scaledFont(11)
                            .foregroundStyle(Color.textSecondary)
                        Text(String(sha.prefix(8)))
                            .scaledFont(11, design: .monospaced)
                            .foregroundStyle(Color.accentBlue)
                            .textSelection(.enabled)
                    }
                    if let commit {
                        Text("by \(commit.authorName), \(DateFormatters.absolute.string(from: commit.date))")
                            .scaledFont(11)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        // A pointer can name a commit this clone has never
                        // fetched. Saying so beats an empty card that looks
                        // like a rendering bug.
                        Text("Not in this clone — fetch the submodule to see it")
                            .scaledFont(11)
                            .foregroundStyle(Color.textDisabled)
                            .lineLimit(1)
                    }
                }
            }

            if let commit {
                Text(commit.subject)
                    .scaledFont(12, weight: .medium)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.bgApp))
        .overlay(
            RoundedRectangle(cornerRadius: 4).stroke(Color.borderColor, lineWidth: 0.5)
        )
    }

    /// Initials, coloured off the author's identity — the same idea as the
    /// Journal's badge, one size up because here it anchors a card rather
    /// than a row.
    private func initialsBadge(for commit: GitCommit?) -> some View {
        Text(Self.initials(of: commit?.authorName ?? "?"))
            .scaledFont(15, weight: .bold)
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Self.color(for: commit))
            )
    }

    static func initials(of name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." })
        let letters = words.prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    private static func color(for commit: GitCommit?) -> Color {
        guard let commit else { return Color.textDisabled }
        let key = commit.authorEmail.isEmpty ? commit.authorName : commit.authorEmail
        let sum = key.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Color.authorBadgePalette[abs(sum) % Color.authorBadgePalette.count]
    }
}
