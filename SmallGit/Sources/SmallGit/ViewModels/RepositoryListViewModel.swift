import Foundation
import Observation

/// Thin wrapper around `AppState`'s persisted repositories, used by the
/// Repositories sidebar panel. Exists so the panel doesn't need to know
/// about the full AppState surface.
@MainActor
@Observable
final class RepositoryListViewModel {

    private(set) weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    /// Internal init used by `AppState` to break the circular construction
    /// order — the binding is set immediately after via `bind(to:)`.
    init(placeholder: Void) {
        self.appState = nil
    }

    func bind(to state: AppState) {
        self.appState = state
    }

    var groups: [RepositoryGroup] {
        appState?.repositoriesConfig.groups ?? []
    }

    var ungrouped: [RepositoryEntry] {
        appState?.repositoriesConfig.ungrouped ?? []
    }

    var activeRepoID: UUID? {
        appState?.activeRepo?.id
    }

    func select(_ repo: RepositoryEntry) async {
        await appState?.selectRepo(repo)
    }

    func remove(_ repo: RepositoryEntry) async {
        await appState?.removeRepository(repo)
    }
}
