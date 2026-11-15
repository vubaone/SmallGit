import SwiftUI

/// Reusable header bar atop every panel (Repositories, Files, Diff, etc.).
/// Renders the panel title left-aligned with an optional trailing accessory
/// view (filter field, picker, action buttons), and an optional control in
/// front of the title.
struct PanelHeader<Leading: View, Trailing: View>: View {
    let title: String
    /// Sits in front of the title, where a disclosure triangle goes. For
    /// controls that act on the panel *itself* rather than its contents —
    /// the Changes/Terminal switch, the collapse arrow — which is why they
    /// read as part of the name rather than as one more button in the row.
    let leading: Leading
    let trailing: Trailing

    init(title: String) where Leading == EmptyView, Trailing == EmptyView {
        self.title = title
        self.leading = EmptyView()
        self.trailing = EmptyView()
    }

    init(
        title: String,
        @ViewBuilder trailing: () -> Trailing
    ) where Leading == EmptyView {
        self.title = title
        self.leading = EmptyView()
        self.trailing = trailing()
    }

    // Both closures are required here: defaulting `trailing` would make
    // `PanelHeader(title:) { … }` ambiguous between this and the
    // trailing-only initializer above, and every header that wants a
    // leading control has a trailing one too.
    init(
        title: String,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 6) {
            leading
                .fixedSize()
            Text(title.uppercased())
                .scaledFont(11, weight: .medium)
                .foregroundStyle(Color.textSecondary)
                // Hard-cap to a single row so the header doesn't
                // stack ("JOURNAL" + "2 commits" on two lines) when
                // the user drags the panel narrow. Title truncates
                // with an ellipsis before the trailing controls
                // (filter field, counts) get squeezed.
                .lineLimit(1)
                .truncationMode(.tail)
                // The title may truncate; what sits beside it may not, or
                // the switch would vanish exactly when the panel is narrow.
                .layoutPriority(0)
            Spacer(minLength: 4)
            trailing
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.bgPanelHeader)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.borderColor)
                .frame(height: 0.5)
        }
    }
}

#Preview {
    PanelHeader(title: "Files") {
        Text("3 files hidden")
            .scaledFont(10)
            .foregroundStyle(Color.textSecondary)
    }
    .frame(width: 400)
    .background(Color.bgPanel)
    .preferredColorScheme(.dark)
}
