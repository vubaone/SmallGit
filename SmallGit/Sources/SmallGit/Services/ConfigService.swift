import Foundation

/// Reads and writes app config / repositories / UI state JSON in the
/// standard macOS Application Support directory.
actor ConfigService {
    static let shared = ConfigService()

    private let fm = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let supportDirectoryOverride: URL?

    init(supportDirectory: URL? = nil) {
        self.supportDirectoryOverride = supportDirectory
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    // MARK: - Paths

    var supportDirectory: URL {
        if let supportDirectoryOverride { return supportDirectoryOverride }
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SmallGit", isDirectory: true)
    }

    var configURL: URL          { Self.configURL(supportDirectory: supportDirectory) }
    var repositoriesURL: URL    { supportDirectory.appendingPathComponent("repositories.json") }
    var uiStateURL: URL         { Self.uiStateURL(supportDirectory: supportDirectory) }

    var hasExistingInstall: Bool {
        fm.fileExists(atPath: supportDirectory.path)
    }

    // MARK: - Setup

    func ensureSupportDirectory() throws {
        if !fm.fileExists(atPath: supportDirectory.path) {
            try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: - App config

    func loadAppConfig() -> AppConfig {
        load(at: configURL) ?? AppConfig()
    }

    func saveAppConfig(_ config: AppConfig) throws {
        try save(config, to: configURL)
    }

    // MARK: - Repositories

    func loadRepositories() -> RepositoriesConfig {
        load(at: repositoriesURL) ?? RepositoriesConfig()
    }

    func saveRepositories(_ repos: RepositoriesConfig) throws {
        try save(repos, to: repositoriesURL)
    }

    // MARK: - UI state

    func loadUIState() -> UIState {
        load(at: uiStateURL) ?? UIState()
    }

    func saveUIState(_ state: UIState) throws {
        try save(state, to: uiStateURL)
    }

    /// Blocking write of the UI state, for the one caller that cannot afford an
    /// async hop: the window has just moved to another display, and the process
    /// may be killed (Force Quit, `kill -9`, Xcode's stop button) before a
    /// `Task` would get to run — losing exactly the position the user just
    /// chose. One small atomic write on the main thread is the cheaper trade.
    ///
    /// `nonisolated` so it runs on the caller's thread rather than hopping onto
    /// the actor, which is the entire point. It touches no mutable actor state:
    /// the path derives from a `let`, and the encoder is created locally.
    nonisolated func saveUIStateBlocking(_ state: UIState) {
        // Logged separately from `config.save` because this one runs on the
        // caller's thread — usually the main thread, during a window drag. If
        // the app ever feels like it stutters while moving windows, this is
        // the row to look at.
        let clock = LogClock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else {
            Log.disk("uistate.saveBlocking", ms: clock.elapsedMs,
                     outcome: .failed, message: "encode failed")
            return
        }
        let url = Self.uiStateURL(supportDirectory: nonisolatedSupportDirectory)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try data.write(to: url, options: [.atomic])
            Log.disk("uistate.saveBlocking", ms: clock.elapsedMs, bytes: data.count)
        } catch {
            Log.disk("uistate.saveBlocking", ms: clock.elapsedMs, bytes: data.count,
                     outcome: .failed, message: error.localizedDescription)
        }
    }

    /// Same location as the actor-isolated `supportDirectory`, reachable
    /// without awaiting. Kept in sync by `saveUIStateBlocking`'s test.
    nonisolated var nonisolatedSupportDirectory: URL {
        if let supportDirectoryOverride { return supportDirectoryOverride }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SmallGit", isDirectory: true)
    }

    nonisolated static func uiStateURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("ui-state.json")
    }

    nonisolated static func configURL(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    /// The persisted appearance, read without awaiting the actor.
    ///
    /// Every other setting can wait for `bootstrap()`, because nothing is on
    /// screen yet when it runs. The appearance can't: AppKit builds the
    /// window and its titlebar before the first `await` completes, so reading
    /// this any later shows a dark titlebar for a frame on a light-themed
    /// launch. A missing or unreadable config means `.system`, which is also
    /// what a first launch should do.
    nonisolated func appearanceBlocking() -> AppearanceMode {
        let url = Self.configURL(supportDirectory: nonisolatedSupportDirectory)
        guard let data = try? Data(contentsOf: url) else { return .system }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(AppConfig.self, from: data))?.appearance ?? .system
    }

    // MARK: - Generic

    private func load<T: Decodable>(at url: URL) -> T? {
        let clock = LogClock()
        guard fm.fileExists(atPath: url.path) else {
            Log.disk("config.load", detail: url.lastPathComponent, ms: clock.elapsedMs,
                     message: "absent")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let value = try decoder.decode(T.self, from: data)
            Log.disk("config.load", detail: url.lastPathComponent, ms: clock.elapsedMs,
                     bytes: data.count)
            return value
        } catch {
            Log.disk("config.load", detail: url.lastPathComponent, ms: clock.elapsedMs,
                     outcome: .failed, message: error.localizedDescription)
            preserveInvalidFile(at: url)
            return nil
        }
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        let clock = LogClock()
        do {
            try ensureSupportDirectory()
            let data = try encoder.encode(value)
            try data.write(to: url, options: [.atomic])
            Log.disk("config.save", detail: url.lastPathComponent, ms: clock.elapsedMs,
                     bytes: data.count)
        } catch {
            Log.disk("config.save", detail: url.lastPathComponent, ms: clock.elapsedMs,
                     outcome: .failed, message: error.localizedDescription)
            throw error
        }
    }

    private func preserveInvalidFile(at url: URL) {
        let timestamp = Int(Date().timeIntervalSince1970)
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).invalid-\(timestamp)")
        guard !fm.fileExists(atPath: backupURL.path) else { return }
        // Move (not copy) so the corrupt original is cleared: the caller
        // falls back to defaults and rewrites a valid file, and we don't
        // re-read and re-back-up the same bad file on every launch.
        try? fm.moveItem(at: url, to: backupURL)
    }
}
