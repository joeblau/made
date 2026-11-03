import Foundation

struct DroneRegistryPersistence {
    private struct Envelope: Codable {
        var schemaVersion: Int
        var drones: [DroneRecord]
    }

    static let maxFileBytes = 1_048_576
    let url: URL

    static func production() -> DroneRegistryPersistence {
        let fileManager = FileManager.default
        let appSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return DroneRegistryPersistence(
            url: appSupport
                .appendingPathComponent("Pilot", isDirectory: true)
                .appendingPathComponent("drones.json")
        )
    }

    func load(fileManager: FileManager = .default) throws -> [DroneRecord] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maxFileBytes else { throw DroneRegistryError.invalidMetadata }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.schemaVersion == 1,
              envelope.drones.count <= DroneLimits.maxPairedWorkers,
              Set(envelope.drones.map(\.id)).count == envelope.drones.count
        else { throw DroneRegistryError.invalidMetadata }
        try envelope.drones.forEach { try $0.validate() }
        return envelope.drones.sorted(by: Self.sort)
    }

    func save(_ drones: [DroneRecord], fileManager: FileManager = .default) throws {
        guard drones.count <= DroneLimits.maxPairedWorkers,
              Set(drones.map(\.id)).count == drones.count
        else { throw DroneRegistryError.invalidMetadata }
        try drones.forEach { try $0.validate() }
        let envelope = Envelope(schemaVersion: 1, drones: drones.sorted(by: Self.sort))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)
        guard data.count <= Self.maxFileBytes else { throw DroneRegistryError.invalidMetadata }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    func remove(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private static func sort(_ lhs: DroneRecord, _ rhs: DroneRecord) -> Bool {
        let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        return order == .orderedSame
            ? lhs.id.uuidString < rhs.id.uuidString
            : order == .orderedAscending
    }
}
