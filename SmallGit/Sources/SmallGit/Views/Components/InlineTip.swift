import SwiftUI

/// A one-sentence explanation shown in place, under a panel header.
///
/// For the controls whose label can't carry their own meaning. A tooltip
/// is the usual answer, and it fails in the usual way: you have to already
/// suspect there is something to learn before you hover long enough to
/// learn it. A tip is on screen while the thing it explains is on screen,
/// and closes when the reader is done with it.
///
/// Deliberately quiet — the same weight as the "N hidden" count, not the
/// orange of `ConflictBanner`. Nothing here is wrong; the reader is just
/// somewhere unfamiliar.
struct InlineTip: View {
    /// Emphasised opening phrase — usually the name of the thing being
    /// explained, so the eye can skip the tip once it knows it.
    var lead: String? = nil
    let message: String
    /// Omit to make the tip permanent for as long as its condition holds.
    var onDismiss: (() -> Void)? = nil

    /// Read directly rather than via `.scaledFont`: that modifier returns
    /// a `View`, and the lead phrase has to stay a `Text` to concatenate
    /// with the message and wrap as one paragraph.
    @Environment(\.uiScale) private var scale

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .scaledFont(11)
                .foregroundStyle(Color.accentBlue)
            text
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .scaledFont(9)
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help("Hide this tip")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.accentBlue.opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.borderColor)
                .frame(height: 0.5)
        }
    }

    /// One `Text`, not two views in an `HStack`: the lead has to wrap
    /// together with the message rather than sit in a column of its own
    /// when the panel is dragged narrow.
    private var text: Text {
        let plain = Font.system(size: 11 * scale)
        guard let lead else { return Text(message).font(plain) }
        return Text(lead).font(.system(size: 11 * scale, weight: .semibold))
            + Text(" — ").font(plain)
            + Text(message).font(plain)
    }
}

#Preview {
    VStack(spacing: 0) {
        PanelHeader(title: "Files")
        InlineTip(
            lead: "Assume unchanged",
            message: "git stops watching these files, so your local edits stay "
                + "out of status, diffs and commits until you clear the flag.",
            onDismiss: {}
        )
    }
    .frame(width: 520)
    .background(Color.bgPanel)
    .preferredColorScheme(.dark)
}
