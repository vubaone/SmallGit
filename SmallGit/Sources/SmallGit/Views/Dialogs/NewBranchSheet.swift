import SwiftUI

struct NewBranchSheet: View {
    @Bindable var appState: AppState
    /// Pre-fill the "Starting point" field — used when invoked via
    /// "New Branch from Here…" on a specific branch in the context menu.
    var initialFrom: String? = nil

    @State private var name: String = ""
    @State private var from: String = ""
    @State private var checkout: Bool = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Branch").font(.title3.bold())

            TextField("Branch name (e.g. feature/login)", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("Starting point")
                Spacer()
                TextField(appState.branchesVM.currentBranch ?? "HEAD", text: $from)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }

            Toggle("Check out immediately", isOn: $checkout)
                .toggleStyle(.checkbox)
                .scaledFont(11)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let start = from.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        await appState.createBranch(
                            name: trimmed,
                            from: start.isEmpty ? nil : start,
                            checkout: checkout
                        )
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(minWidth: 460)
        .background(Color.bgPanel)
        .onAppear {
            if let initialFrom, from.isEmpty { from = initialFrom }
        }
    }
}
