import SwiftUI

/// Centered "nothing to show" placeholder shared by the Files,
/// Journal, and Branches panels when no repository is open. Keeping
/// the visual language consistent across panels reads as "the whole
/// workspace is idle", not "this one panel failed to load".
struct EmptyPanelState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .scaledFont(28, weight: .light)
                .foregroundStyle(Color.textDisabled)
            Text(title)
                .scaledFont(12, weight: .medium)
                .foregroundStyle(Color.textSecondary)
            Text(message)
                .scaledFont(10)
                .foregroundStyle(Color.textDisabled)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bgPanel)
    }
}
