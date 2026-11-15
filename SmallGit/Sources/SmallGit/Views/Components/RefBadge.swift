import SwiftUI

/// Parses git's `%D` ref-names output (the `commit.refs` string) into
/// typed pieces so the Journal view can render them as colored chips
/// before the subject — the SmartGit-style "main", "origin/main",
/// "tag: v1.0.0" inline labels.
///
/// Example input: `"HEAD -> main, origin/main, tag: v1.0.0, feature/x"`
struct CommitRefLabel: Hashable, Identifiable {
    enum Kind: Hashable {
        case head            // current branch the user is on
        case localBranch
        case remoteBranch
        case tag
    }

    let name: String
    let kind: Kind

    var id: String { "\(kind):\(name)" }
}

enum RefParser {
    static func parse(_ refs: String) -> [CommitRefLabel] {
        var out: [CommitRefLabel] = []
        for raw in refs.split(separator: ",") {
            let token = raw.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }

            if token.hasPrefix("HEAD -> ") {
                let name = String(token.dropFirst("HEAD -> ".count))
                out.append(CommitRefLabel(name: name, kind: .head))
            } else if token == "HEAD" {
                // Detached HEAD (no branch label after "->")
                out.append(CommitRefLabel(name: "HEAD", kind: .head))
            } else if token.hasPrefix("tag: ") {
                out.append(CommitRefLabel(
                    name: String(token.dropFirst("tag: ".count)),
                    kind: .tag
                ))
            } else if token.contains("/") {
                // Heuristic: refs containing "/" are remote-tracking
                // (origin/main, upstream/feature/x, …). Local branches
                // can contain slashes too (feature/login) but git's
                // refname disambiguation prefixes the remote name with
                // the remote, so we treat anything with a slash here as
                // remote — same convention SmartGit uses.
                out.append(CommitRefLabel(name: token, kind: .remoteBranch))
            } else {
                out.append(CommitRefLabel(name: token, kind: .localBranch))
            }
        }
        return out
    }
}

/// Pill-style label rendered inline before a commit's subject.
struct RefBadge: View {
    let label: CommitRefLabel

    var body: some View {
        HStack(spacing: 3) {
            if label.kind == .head {
                Image(systemName: "arrow.right")
                    .scaledFont(8, weight: .bold)
            } else if label.kind == .tag {
                Image(systemName: "tag.fill")
                    .scaledFont(8)
            }
            Text(label.name)
                .scaledFont(10, weight: .medium)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(backgroundColor)
        )
        .help(label.name)
    }

    private var backgroundColor: Color {
        switch label.kind {
        case .head:         return Color(red: 0.18, green: 0.55, blue: 0.25)  // dark green
        case .localBranch:  return Color(red: 0.20, green: 0.40, blue: 0.75)  // blue
        case .remoteBranch: return Color(red: 0.75, green: 0.45, blue: 0.15)  // orange
        case .tag:          return Color(red: 0.45, green: 0.30, blue: 0.65)  // purple
        }
    }
}
