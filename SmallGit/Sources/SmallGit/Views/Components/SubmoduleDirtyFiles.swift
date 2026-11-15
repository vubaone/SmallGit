import SwiftUI

/// Uncommitted work inside a submodule, listed by file.
///
/// SmartGit surfaces these by folding them into the parent's Files table,
/// with the submodule's own path in the directory column. They are listed
/// here instead, under the submodule they belong to, because that is where
/// they can be acted on: staging one from the parent would stage nothing —
/// the parent records commits, not the edits inside them.
struct SubmoduleDirtyFiles: View {
    let change: SubmoduleChange

    private var name: String { (change.path as NSString).lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("UNCOMMITTED INSIDE \(name.uppercased())")
                .scaledFont(9, weight: .medium)
                .foregroundStyle(Color.textSecondary)

            ForEach(change.dirtyFiles) { file in
                HStack(spacing: 8) {
                    FileStatusDot(file: file, color: file.displaySwatch)
                    Text(file.name)
                        .scaledFont(11)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    Text(file.relativeDirectory == "." ? "" : file.relativeDirectory)
                        .scaledFont(10, design: .monospaced)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 8)
                    Text(file.stateDisplay)
                        .scaledFont(10)
                        .foregroundStyle(file.displaySwatch)
                        .fixedSize()
                }
                .padding(.vertical, 1)
            }

            // The thing that is actually confusing about this state, said
            // once: the parent cannot record an edit, only a commit.
            Text("These belong to \(name). Commit them there, then the parent can record the new commit.")
                .scaledFont(10)
                .foregroundStyle(Color.textDisabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
