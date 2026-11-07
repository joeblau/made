import Foundation
import Testing
@testable import Pilot

@Suite("Agent model catalog and favorites")
struct AgentModelCatalogTests {
    @Test("Snapshots keep each agent's advertised models and thought levels", arguments: ChatAgent.allCases)
    func snapshotsRoundTrip(_ agent: ChatAgent) throws {
        let (catalog, done) = try makeCatalog()
        defer { done() }
        let config = try #require(ACPSessionConfig(ACPProbeFixtures.result(agent)))
        #expect(catalog.snapshot(for: agent) == nil)
        #expect(catalog.record(config, for: agent))
        // Unchanged configuration is not written again.
        #expect(!catalog.record(config, for: agent))
        let snapshot = try #require(catalog.snapshot(for: agent))
        let model = try #require(config.model)
        #expect(snapshot.models.map(\.id) == model.choices.map(\.id))
        #expect(snapshot.models.map(\.name) == model.choices.map(\.name))
        #expect(snapshot.currentModelID == model.currentID)
        #expect(snapshot.thoughtLevels.map(\.id) == config.thoughtLevel?.choices.map(\.id) ?? [])
        #expect(snapshot.thoughtLevelName == config.thoughtLevel?.name)
        #expect(snapshot.currentThoughtLevelID == config.thoughtLevel?.currentID)
        for other in ChatAgent.allCases where other != agent { #expect(catalog.snapshot(for: other) == nil) }
    }

    @Test
    func aConfigurationWithoutModelChoicesKeepsThePreviousSnapshot() throws {
        let (catalog, done) = try makeCatalog()
        defer { done() }
        let grok = try #require(ACPSessionConfig(ACPProbeFixtures.result(.grok)))
        catalog.record(grok, for: .grok)
        let bare = try #require(ACPSessionConfig(["_meta": ["modelState": ["currentModelId": "grok-4.7"]]]))
        #expect(!catalog.record(bare, for: .grok))
        #expect(catalog.snapshot(for: .grok)?.currentModelID == "grok-4.7-build-fast")
        catalog.removeSnapshot(for: .grok)
        #expect(catalog.snapshot(for: .grok) == nil)
    }

    @Test
    func snapshotsAreBoundedInCountAndSize() throws {
        let (catalog, done) = try makeCatalog()
        defer { done() }
        let choices = (0..<500).map { index in
            ACPConfigOption.Choice(id: "model-\(index)-" + String(repeating: "i", count: 200),
                                   name: String(repeating: "n", count: 500),
                                   detail: String(repeating: "d", count: 2_000), group: "Group")
        }
        let config = ACPSessionConfig(options: [
            ACPConfigOption(id: "model", name: "Model", category: .model, currentID: choices[0].id, choices: choices),
        ])
        #expect(catalog.record(config, for: .cursor))
        let data = try #require(catalog.defaults.data(forKey: AgentModelCatalog.snapshotKey(for: .cursor)))
        #expect(data.count <= AgentModelCatalog.maximumEncodedBytes)
        let snapshot = try #require(catalog.snapshot(for: .cursor))
        #expect(snapshot.models.count < AgentModelCatalog.maximumModels)
        #expect(snapshot.models.first?.id == choices[0].id)
        #expect(snapshot.models.allSatisfy { $0.detail == nil && $0.group == "Group" })

        let small = (0..<300).map { ACPConfigOption.Choice(id: "m\($0)", name: "Model \($0)") }
        catalog.record(ACPSessionConfig(options: [
            ACPConfigOption(id: "model", name: "Model", category: .model, currentID: "m0", choices: small),
        ]), for: .cursor)
        #expect(catalog.snapshot(for: .cursor)?.models.count == AgentModelCatalog.maximumModels)
    }

    @Test
    func corruptOrTamperedSnapshotsAreIgnoredOrRebounded() throws {
        let (catalog, done) = try makeCatalog()
        defer { done() }
        let key = AgentModelCatalog.snapshotKey(for: .kimi)
        catalog.defaults.set(Data("not json".utf8), forKey: key)
        #expect(catalog.snapshot(for: .kimi) == nil)
        catalog.defaults.set("a string", forKey: key)
        #expect(catalog.snapshot(for: .kimi) == nil)
        catalog.defaults.set(Data(repeating: 0x20, count: AgentModelCatalog.maximumEncodedBytes + 1), forKey: key)
        #expect(catalog.snapshot(for: .kimi) == nil)

        let tampered = #"""
        {"models":[{"id":"","name":"Empty"},{"id":"k3","name":"‮K3​"},{"id":"k3","name":"Again"},
          {"id":"\#(String(repeating: "x", count: 300))","name":"Long"}],"thoughtLevels":[]}
        """#
        catalog.defaults.set(Data(tampered.utf8), forKey: key)
        let snapshot = try #require(catalog.snapshot(for: .kimi))
        #expect(snapshot.models == [.init(id: "k3", name: "K3")])
        catalog.defaults.set(Data(#"{"models":[],"thoughtLevels":[]}"#.utf8), forKey: key)
        #expect(catalog.snapshot(for: .kimi) == nil)
    }

    // MARK: Favorites

    @Test
    func favoritesKeepTheirOrderAcrossProviders() throws {
        let (catalog, done) = try makeCatalog()
        defer { done() }
        let sonnet = AgentModelCatalog.Favorite(agent: .claude, modelID: "sonnet")
        let luna = AgentModelCatalog.Favorite(agent: .codex, modelID: "gpt-6-luna")
        let k3 = AgentModelCatalog.Favorite(agent: .kimi, modelID: "kimi-code/k3")
        #expect(catalog.addFavorite(luna) && catalog.addFavorite(sonnet) && catalog.addFavorite(k3))
        #expect(!catalog.addFavorite(sonnet))
        #expect(catalog.favorites() == [luna, sonnet, k3])
        catalog.removeFavorite(sonnet)
        #expect(catalog.favorites() == [luna, k3])
        #expect(catalog.toggleFavorite(sonnet) && catalog.isFavorite(sonnet))
        #expect(catalog.favorites() == [luna, k3, sonnet])
        #expect(!catalog.toggleFavorite(luna) && !catalog.isFavorite(luna))
        #expect(!catalog.addFavorite(.init(agent: .grok, modelID: "")))
        #expect(!catalog.addFavorite(.init(agent: .grok, modelID: String(repeating: "g", count: 257))))
    }

    @Test
    func favoritesUseCachedNamesAndFallBackToTheID() throws {
        let (catalog, done) = try makeCatalog()
        defer { done() }
        for agent in [ChatAgent.claude, .codex] {
            catalog.record(try #require(ACPSessionConfig(ACPProbeFixtures.result(agent))), for: agent)
        }
        catalog.addFavorite(.init(agent: .codex, modelID: "gpt-6.1-sol"))
        catalog.addFavorite(.init(agent: .claude, modelID: "opus"))
        catalog.addFavorite(.init(agent: .claude, modelID: "retired-model"))
        catalog.addFavorite(.init(agent: .grok, modelID: "grok-4.7"))
        let entries = catalog.favoriteEntries()
        #expect(entries.map(\.name) == ["6.1 Sol", "Opus 5.5", "retired-model", "grok-4.7"])
        #expect(entries.first?.detail == "Latest workhorse model for coding and everyday work.")
        #expect(entries.map(\.favorite.agent) == [.codex, .claude, .claude, .grok])
    }

    @Test
    func favoritesAreCappedAndCorruptEntriesAreIgnored() throws {
        let (catalog, done) = try makeCatalog()
        defer { done() }
        for index in 0..<AgentModelCatalog.maximumFavorites {
            #expect(catalog.addFavorite(.init(agent: .cursor, modelID: "m\(index)")))
        }
        #expect(!catalog.addFavorite(.init(agent: .cursor, modelID: "one-more")))
        #expect(catalog.favorites().count == AgentModelCatalog.maximumFavorites)

        catalog.defaults.set([
            ["agent": "claude", "model": "opus"],
            ["agent": "unknown", "model": "x"],
            ["agent": "codex"],
            "not a dictionary",
            ["agent": "claude", "model": "opus"],
            ["agent": "grok", "model": ""],
            ["agent": "kimi", "model": "kimi-code/k3"],
        ] as [Any], forKey: AgentModelCatalog.favoritesKey)
        #expect(catalog.favorites() == [.init(agent: .claude, modelID: "opus"), .init(agent: .kimi, modelID: "kimi-code/k3")])
        catalog.defaults.set("garbage", forKey: AgentModelCatalog.favoritesKey)
        #expect(catalog.favorites().isEmpty)
        #expect(catalog.addFavorite(.init(agent: .claude, modelID: "opus")))
    }

    private func makeCatalog() throws -> (AgentModelCatalog, () -> Void) {
        let name = "AgentModelCatalogTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (AgentModelCatalog(defaults: defaults), { defaults.removePersistentDomain(forName: name) })
    }
}
