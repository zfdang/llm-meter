import Foundation
import LLMMeterCore
import Testing

@testable import LLMMeterApp

@MainActor
private func preview(metrics: [UsageMetric]) throws -> (AppStore, URL) {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let storage = LocalStorage(directory: directory)
  var settings = AppSettings()
  settings.selectedProvider = .antigravity
  try storage.saveSettings(settings)
  let now = Date()
  // The preview binds the Codex account; use the same fictional ID for both services.
  let snapshots = [ProviderID.codex, .antigravity].map {
    UsageSnapshot(
      provider: $0, accountID: "fixture", accountLabel: "Fixture",
      metrics: metrics, readAt: now)
  }
  return (AppStore.screenshotPreview(storage: storage, snapshots: snapshots, now: now), directory)
}

@Test @MainActor func legacyNonGeminiSelectionUsesGeminiFiveHourPool() throws {
  let now = Date()
  let (store, directory) = try preview(metrics: [
    .init(
      id: "fiveHours", name: "Non-Gemini", period: .fiveHours,
      scope: "pool:Non-Gemini Models", usedPercent: 99, readAt: now),
    .init(
      id: "gemini-week", name: "Weekly", period: .weekly,
      scope: "pool:Gemini Models", usedPercent: 40, readAt: now),
    .init(
      id: "gemini-5h", name: "5h", period: .fiveHours,
      scope: "pool:Gemini Models", usedPercent: 12, readAt: now),
  ])
  defer { try? FileManager.default.removeItem(at: directory) }
  #expect(store.menuBarValue == "12%")
  #expect(store.menuBarMetricID == "gemini-5h")
  #expect(store.menuBarMetrics.map(\.id) == ["gemini-week", "gemini-5h"])
  #expect(store.antigravityPools.count == 2)
}

@Test @MainActor func geminiModelFallbackAndMissingQuotaDoNotUseOtherModels() throws {
  let now = Date()
  let other = UsageMetric(id: "fiveHours", name: "Claude", usedPercent: 99, readAt: now)
  let gemini = UsageMetric(id: "gemini-pro", name: "Gemini Pro", usedPercent: 7, readAt: now)
  let (store, directory) = try preview(metrics: [other, gemini])
  defer { try? FileManager.default.removeItem(at: directory) }
  #expect(store.menuBarValue == "7%")
  #expect(store.menuBarMetrics.map(\.id) == ["gemini-pro"])
  let (missing, missingDirectory) = try preview(metrics: [other])
  defer { try? FileManager.default.removeItem(at: missingDirectory) }
  #expect(missing.menuBarValue == "—")
  #expect(missing.menuBarMetrics.isEmpty)
}

@Test @MainActor func explicitGeminiWeeklySelectionIsPreserved() throws {
  let now = Date()
  let (store, directory) = try preview(metrics: [
    .init(
      id: "gemini-5h", name: "5h", period: .fiveHours,
      scope: "pool:Gemini Models", usedPercent: 12, readAt: now),
    .init(
      id: "fiveHours", name: "Weekly", period: .weekly,
      scope: "pool:Gemini Models", usedPercent: 40, readAt: now),
  ])
  defer { try? FileManager.default.removeItem(at: directory) }
  #expect(store.menuBarValue == "40%")
}
