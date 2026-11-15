import SwiftUI

/// App-themed replacement for the synchronous AppKit repository-removal
/// alert. It distinguishes the reversible list-only action from moving the
/// working folder to Trash, and keeps the saved path visible for context.
struct RepositoryRemovalSheet: View {
    @Bindable var appState: AppState
    let target: AppState.RepositoryRemovalTarget

    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false
    @State private var errorMessage: String?

    private var repository: RepositoryEntry { target.repository }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            explanation
            pathCard

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(11)
                    .foregroundStyle(Color.diffDelText)
            }

            Divider()

            actions
        }
        .padding(20)
        .frame(width: 500)
        .background(Color.bgPanel)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: target.folderExists ? "folder.badge.minus" : "questionmark.folder")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(target.folderExists ? Color.orange : Color.textSecondary)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill((target.folderExists ? Color.orange : Color.textSecondary).opacity(0.13))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("Remove Repository")
                    .font(.title3.bold())
                    .foregroundStyle(Color.textPrimary)
                Text(repository.name)
                    .scaledFont(12, weight: .medium)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var explanation: some View {
        if target.folderExists {
            Text("Remove only the saved entry from SmallGit, or move the repository folder and all of its files to Trash too.")
                .scaledFont(12)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Color.accentBlue)
                    .padding(.top, 1)
                Text("This folder is no longer available on disk. You can remove its saved entry from SmallGit.")
                    .scaledFont(12)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.accentBlue.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.accentBlue.opacity(0.25), lineWidth: 0.5)
                    )
            )
        }
    }

    private var pathCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("REPOSITORY FOLDER")
                .scaledFont(9, weight: .semibold)
                .foregroundStyle(Color.textDisabled)
                .tracking(0.6)

            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(Color.textSecondary)
                Text(repository.path)
                    .scaledFont(11, design: .monospaced)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.bgInput)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.borderColor, lineWidth: 0.5)
                )
        )
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Cancel", role: .cancel) {
                appState.cancelRepositoryRemoval()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isWorking)

            Spacer()

            Button("Remove from List") {
                perform(.removeFromList)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(isWorking)

            if target.folderExists {
                Button("Move Folder to Trash", role: .destructive) {
                    perform(.moveFolderToTrash)
                }
                .disabled(isWorking)
            }
        }
    }

    private func perform(_ choice: AppState.RepositoryRemovalChoice) {
        isWorking = true
        errorMessage = nil
        Task {
            let didComplete = await appState.confirmRepositoryRemoval(target, choice: choice)
            isWorking = false
            if didComplete {
                dismiss()
            } else {
                errorMessage = "The folder could not be moved to Trash. Check that it is still available and try again."
            }
        }
    }
}
