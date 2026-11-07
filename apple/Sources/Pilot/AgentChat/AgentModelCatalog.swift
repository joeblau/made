import Foundation

/// The models each agent last advertised, and the user's favorite models
/// across agents, in `UserDefaults`.
///
/// A snapshot is written whenever a session's configuration arrives, so the
/// model picker can list another provider's models without launching it. It
/// is a cache of what the agent itself advertised, never a hard-coded list:
/// selecting a cached model still goes through the agent, which may refuse.
/// Stored data is untrusted on read: oversized or corrupt values are ignored
/// and every field is re-bounded.
struct AgentModelCatalog {
    struct Entry: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var detail: String?
        var group: String?
    }

    struct Snapshot: Codable, Equatable, Sendable {
        var models: [Entry]
        var currentModelID: String?
        /// The thought-level option's name, for display normalization.
        var thoughtLevelName: String?
        var thoughtLevels: [Entry]
        var currentThoughtLevelID: String?
    }

    struct Favorite: Equatable, Hashable, Sendable {
        var agent: ChatAgent
        var modelID: String
    }

    /// A favorite with the name and description its agent last advertised;
    /// `name` falls back to the sanitized model ID when the agent's snapshot lacks it.
    struct FavoriteEntry: Equatable, Sendable {
        var favorite: Favorite
        var name: String
        var detail: String?
    }

    static let maximumModels = 200
    static let maximumThoughtLevels = 32
    static let maximumEncodedBytes = 64 * 1_024
    static let maximumFavorites = 50
    static let favoritesKey = "agentChat.favoriteModels"

    static func snapshotKey(for agent: ChatAgent) -> String { "agentChat.modelCatalog.\(agent.rawValue)" }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Snapshots

    func snapshot(for agent: ChatAgent) -> Snapshot? {
        guard let data = defaults.data(forKey: Self.snapshotKey(for: agent)), data.count <= Self.maximumEncodedBytes,
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        let snapshot = decoded.bounded()
        return snapshot.models.isEmpty ? nil : snapshot
    }

    /// Saves the model and thought-level options `config` advertises. A
    /// configuration without model choices (such as a bare current model ID)
    /// keeps the previous snapshot. Returns whether anything was written.
    @discardableResult
    func record(_ config: ACPSessionConfig, for agent: ChatAgent) -> Bool {
        guard let snapshot = Self.snapshot(of: config), let data = Self.encode(snapshot) else { return false }
        let key = Self.snapshotKey(for: agent)
        guard defaults.data(forKey: key) != data else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    func removeSnapshot(for agent: ChatAgent) {
        defaults.removeObject(forKey: Self.snapshotKey(for: agent))
    }

    static func snapshot(of config: ACPSessionConfig) -> Snapshot? {
        guard let model = config.model, !model.choices.isEmpty else { return nil }
        let level = config.thoughtLevel
        return Snapshot(
            models: model.choices.prefix(maximumModels).map(Entry.init),
            currentModelID: model.currentID,
            thoughtLevelName: level?.name,
            thoughtLevels: (level?.choices ?? []).prefix(maximumThoughtLevels).map(Entry.init),
            currentThoughtLevelID: level?.currentID
        )
    }

    /// Sorted-key JSON within 64 KiB: descriptions are dropped first, then
    /// models from the end, until it fits.
    static func encode(_ snapshot: Snapshot) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var candidate = snapshot.bounded()
        guard let full = try? encoder.encode(candidate) else { return nil }
        if full.count <= maximumEncodedBytes { return full }
        candidate.models = candidate.models.map { Entry(id: $0.id, name: $0.name, group: $0.group) }
        candidate.thoughtLevels = candidate.thoughtLevels.map { Entry(id: $0.id, name: $0.name) }
        while let data = try? encoder.encode(candidate) {
            if data.count <= maximumEncodedBytes { return data }
            guard candidate.models.count > 1 else { return nil }
            candidate.models.removeLast(max(candidate.models.count / 4, 1))
        }
        return nil
    }

    // MARK: - Favorites

    /// Favorites in the order they were added, at most 50.
    func favorites() -> [Favorite] {
        guard let raw = defaults.array(forKey: Self.favoritesKey) else { return [] }
        var favorites: [Favorite] = []
        var seen = Set<Favorite>()
        for item in raw.prefix(Self.maximumFavorites * 4) {
            guard favorites.count < Self.maximumFavorites, let fields = item as? [String: String],
                  let agent = fields["agent"].flatMap(ChatAgent.init(rawValue:)),
                  let modelID = ACPConfigText.id(fields["model"].map(JSONValue.string)) else { continue }
            let favorite = Favorite(agent: agent, modelID: modelID)
            if seen.insert(favorite).inserted { favorites.append(favorite) }
        }
        return favorites
    }

    func isFavorite(_ favorite: Favorite) -> Bool { favorites().contains(favorite) }

    /// Appends `favorite`. False when it is already a favorite, its ID is
    /// malformed, or 50 favorites are saved.
    @discardableResult
    func addFavorite(_ favorite: Favorite) -> Bool {
        var current = favorites()
        guard !current.contains(favorite), current.count < Self.maximumFavorites,
              ACPConfigText.id(.string(favorite.modelID)) != nil else { return false }
        current.append(favorite)
        save(current)
        return true
    }

    func removeFavorite(_ favorite: Favorite) {
        let current = favorites()
        guard current.contains(favorite) else { return }
        save(current.filter { $0 != favorite })
    }

    /// Adds or removes `favorite`; returns whether it is a favorite afterwards.
    @discardableResult
    func toggleFavorite(_ favorite: Favorite) -> Bool {
        if isFavorite(favorite) {
            removeFavorite(favorite)
            return false
        }
        return addFavorite(favorite)
    }

    /// Favorites with the names their agents last advertised.
    func favoriteEntries() -> [FavoriteEntry] {
        var snapshots: [ChatAgent: Snapshot?] = [:]
        return favorites().map { favorite in
            if snapshots[favorite.agent] == nil { snapshots[favorite.agent] = .some(snapshot(for: favorite.agent)) }
            let entry = snapshots[favorite.agent]??.models.first { $0.id == favorite.modelID }
            return FavoriteEntry(favorite: favorite, name: entry?.name ?? ACPConfigText.label(forID: favorite.modelID),
                                 detail: entry?.detail)
        }
    }

    private func save(_ favorites: [Favorite]) {
        defaults.set(favorites.map { ["agent": $0.agent.rawValue, "model": $0.modelID] }, forKey: Self.favoritesKey)
    }
}

private extension AgentModelCatalog.Entry {
    init(_ choice: ACPConfigOption.Choice) {
        self.init(id: choice.id, name: choice.name, detail: choice.detail, group: choice.group)
    }

    /// Nil when the ID is malformed; text is re-sanitized and re-bounded.
    func bounded() -> Self? {
        guard let id = ACPConfigText.id(.string(id)) else { return nil }
        return Self(
            id: id,
            name: ACPConfigText.name(.string(name)) ?? ACPConfigText.label(forID: id),
            detail: detail.flatMap { ACPConfigText.detail(.string($0)) },
            group: group.flatMap { ACPConfigText.name(.string($0)) }
        )
    }
}

private extension AgentModelCatalog.Snapshot {
    func bounded() -> Self {
        Self(
            models: Self.unique(models.prefix(AgentModelCatalog.maximumModels).compactMap { $0.bounded() }),
            currentModelID: currentModelID.flatMap { ACPConfigText.id(.string($0)) },
            thoughtLevelName: thoughtLevelName.flatMap { ACPConfigText.name(.string($0)) },
            thoughtLevels: Self.unique(thoughtLevels.prefix(AgentModelCatalog.maximumThoughtLevels).compactMap { $0.bounded() }),
            currentThoughtLevelID: currentThoughtLevelID.flatMap { ACPConfigText.id(.string($0)) }
        )
    }

    static func unique(_ entries: [AgentModelCatalog.Entry]) -> [AgentModelCatalog.Entry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.id).inserted }
    }
}
