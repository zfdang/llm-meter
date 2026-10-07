import Foundation

public struct CacheFile: Codable, Sendable {
  public var schemaVersion = 1
  public var snapshots: [UsageSnapshot]
  public init(snapshots: [UsageSnapshot]) { self.snapshots = snapshots }
}

public struct LocalStorage: Sendable {
  public let directory: URL
  public init(
    directory: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/LLM Meter", isDirectory: true)
  ) {
    self.directory = directory
  }
  public func loadSettings() throws -> AppSettings {
    let settings: AppSettings = try read("settings.json") ?? AppSettings()
    try settings.validate()
    return settings
  }
  public func saveSettings(_ settings: AppSettings) throws {
    try settings.validate()
    try write(settings, name: "settings.json")
  }
  public func loadCache() throws -> [UsageSnapshot] {
    guard let cache: CacheFile = try read("usage-cache.json") else { return [] }
    guard cache.schemaVersion == 1,
      Set(cache.snapshots.map(\.provider)).count == cache.snapshots.count,
      cache.snapshots.allSatisfy({ snapshot in
        !snapshot.accountID.isEmpty
          && Set(snapshot.metrics.map(\.id)).count == snapshot.metrics.count
          && snapshot.metrics.allSatisfy { $0.usedPercent.map { $0.isFinite && $0 >= 0 } ?? true }
      })
    else { throw MeterError.storage("Invalid or unsupported cache. Original file preserved.") }
    return cache.snapshots
  }
  public func saveCache(_ snapshots: [UsageSnapshot]) throws {
    try write(CacheFile(snapshots: snapshots), name: "usage-cache.json")
  }
  private func read<T: Decodable>(_ name: String) throws -> T? {
    let url = directory.appendingPathComponent(name)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: url)) } catch {
      throw MeterError.storage("Cannot read \(name). Original file preserved.")
    }
  }
  private func write<T: Encodable>(_ value: T, name: String) throws {
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(value)
      // Set permissions on the temporary file before exposing it at the destination.
      let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
      defer { try? FileManager.default.removeItem(at: temporary) }
      guard
        FileManager.default.createFile(
          atPath: temporary.path, contents: data,
          attributes: [.posixPermissions: 0o600])
      else {
        throw MeterError.storage("Could not create a storage file.")
      }
      let destination = directory.appendingPathComponent(name)
      guard rename(temporary.path, destination.path) == 0 else {
        throw MeterError.storage("Could not replace a storage file.")
      }
    } catch { throw MeterError.storage("Could not save \(name). Check folder permissions.") }
  }
}
