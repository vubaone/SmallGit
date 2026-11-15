import SwiftUI

/// One submodule in the Branches panel's Submodules section.
///
/// Shows the pointer's state rather than the submodule's own branch: from the
/// parent repository's side, what matters is whether the checkout agrees with
/// the commit the parent records. The submodule's branches and history are one
/// double-click away, in a repository row of its own.
struct SubmoduleRow: View {
    let submodule: GitSubmodule

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .scaledFont(10)
                .foregroundStyle(tint)
            Text(submodule.name)
                .scaledFont(11)
                .lineLimit(1)
                .truncationMode(.middle)
            // The describe when git offered one — `v1.2-3-gabc1234` says far
            // more at a glance than a bare SHA — falling back to the SHA,
            // which is all an uninitialised submodule has.
            Text(submodule.describe ?? submodule.shortSHA)
                .scaledFont(9, design: .monospaced)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if submodule.state != .current {
                Text(submodule.state.label)
                    .scaledFont(9)
                    .foregroundStyle(tint)
            }
        }
        .help(helpText)
        .toolTip(helpText)
    }

    private var icon: String {
        switch submodule.state {
        case .current:       return "shippingbox"
        case .uninitialized: return "shippingbox.circle"
        case .modified:      return "shippingbox.fill"
        case .conflicted:    return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch submodule.state {
        case .current:       return Color.textSecondary
        case .uninitialized: return Color.textDisabled
        case .modified:      return .orange
        case .conflicted:    return .red
        }
    }

    private var helpText: String {
        var lines = [submodule.path]
        if let url = submodule.url { lines.append(url) }
        switch submodule.state {
        case .current:
            lines.append("At the commit this repository records.")
        case .uninitialized:
            lines.append("Not cloned yet — use Update to fetch it.")
        case .modified:
            lines.append("Checked out at a different commit than this repository records. Committing here would move the pointer.")
        case .conflicted:
            lines.append("Two branches moved this submodule to different commits.")
        }
        return lines.joined(separator: "\n")
    }
}
