import AppKit
import Foundation
import LLMMeterCore
import SwiftUI
import Testing

@testable import LLMMeterApp

private final class Clock: @unchecked Sendable {
  private let lock = NSLock()
  private var date = Date()
  func now() -> Date { lock.withLock { date } }
  func advance() { lock.withLock { date.addTimeInterval(200) } }
}
private actor Source: UsageProvider {
  let clock: Clock
  var response: Result<Double, MeterError> = .success(42)
  init(clock: Clock) { self.clock = clock }
  func respond(_ result: Result<Double, MeterError>) { response = result }
  func fetch(configuration: ServiceConfiguration) async throws -> UsageSnapshot {
    let used = try response.get()
    return UsageSnapshot(
      provider: .codex, accountID: "fixture", accountLabel: "Fixture",
      metrics: [
        .init(
          id: "primary", name: "5h", period: .fiveHours,
          usedPercent: used, readAt: clock.now())
      ], readAt: clock.now())
  }
}

@Test @MainActor func automaticRefreshUpdatesPublishedLabelsAndTones() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let storage = LocalStorage(directory: directory)
  var settings = AppSettings()
  for index in settings.services.indices {
    settings.services[index].enabled = settings.services[index].provider == .codex
  }
  settings.refreshMinutes = 1
  try storage.saveSettings(settings)
  let clock = Clock()
  let source = Source(clock: clock)
  let store = AppStore(storage: storage, provider: source, clock: { clock.now() })
  _ = NSApplication.shared
  let host = NSHostingView(
    rootView: UsagePanel(store: store, maximumContentHeight: { 700 }, openSettings: {})
      .environment(\.colorScheme, .light))
  host.frame = NSRect(x: 0, y: 0, width: 380, height: 470)
  let window = NSWindow(
    contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
  window.contentView = host
  window.orderFront(nil)
  defer { window.orderOut(nil) }
  func coloredPixels(red: Bool) async throws -> Int {
    try await Task.sleep(for: .milliseconds(80))
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
      Issue.record("Cannot render native usage panel")
      return 0
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    var count = 0
    for x in 0..<bitmap.pixelsWide {
      for y in 0..<bitmap.pixelsHigh {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        if red
          ? color.redComponent > color.greenComponent + 0.2
          : color.greenComponent > color.redComponent + 0.15
            && color.greenComponent > color.blueComponent + 0.1
        {
          count += 1
        }
      }
    }
    return count
  }
  store.start()
  func settle(_ predicate: () -> Bool) async throws {
    for _ in 0..<200 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Published refresh state did not settle")
  }
  try await settle { store.states[.codex]?.confirmed == true }
  #expect(store.label(.codex, period: .fiveHours) == "42%")
  #expect(store.tone(.codex, metric: store.metric(.codex, period: .fiveHours)) == .low)
  #expect(try await coloredPixels(red: false) > 10)
  await source.respond(.failure(.network))
  clock.advance()
  await store.coordinator.refresh()  // Scheduled path, never manual Refresh.
  try await settle { store.states[.codex]?.error == .network }
  #expect(store.label(.codex, period: .fiveHours) == "42%·")
  #expect(store.tone(.codex, metric: store.metric(.codex, period: .fiveHours)) == .unknown)
  #expect(try await coloredPixels(red: false) == 0)
  await source.respond(.success(85))
  clock.advance()
  await store.coordinator.refresh()
  try await settle { store.states[.codex]?.snapshot?.metrics.first?.usedPercent == 85 }
  #expect(store.states[.codex]?.error == nil)
  #expect(store.label(.codex, period: .fiveHours) == "85%")
  #expect(store.tone(.codex, metric: store.metric(.codex, period: .fiveHours)) == .high)
  #expect(store.serviceStatusLabel(.codex) == nil)
  #expect(try await coloredPixels(red: true) > 10)
  await store.stop()
}
