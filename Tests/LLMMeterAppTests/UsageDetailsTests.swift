import AppKit
import Foundation
import LLMMeterCore
import SwiftUI
import Testing

@testable import LLMMeterApp

@Test @MainActor func longDetailsStayBoundedAndCanScrollToTheLastMetric() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let now = Date()
  let metrics = (0..<60).map { index in
    UsageMetric(
      id: "model-\(index)", name: "Fixture model \(index)", period: .other,
      scope: index == 0 ? "pool:Fixture group" : nil,
      usedPercent: 42, resetAt: now.addingTimeInterval(1800), readAt: now)
  }
  let snapshot = UsageSnapshot(
    provider: .antigravity, accountID: "fixture", accountLabel: "Demo account",
    metrics: metrics, readAt: now)
  let store = AppStore.screenshotPreview(
    storage: LocalStorage(directory: directory), snapshots: [snapshot], now: now)
  #expect(store.detailsText(.antigravity).contains("Fixture model 59"))
  #expect(store.detailsText(.antigravity).contains("Fixture group"))
  #expect(!store.hoverSummary(.antigravity).contains("Fixture model"))
  #expect(store.hoverSummary(.antigravity).split(separator: "\n").count <= 3)
  _ = NSApplication.shared
  let host = NSHostingView(
    rootView: UsageDetailsView(
      store: store, provider: .antigravity,
      maximumContentHeight: { 260 }, back: {}
    ).environment(\.colorScheme, .light))
  let size = host.fittingSize
  #expect(size.width == 380)
  #expect(size.height < 400)
  let window = NSWindow(
    contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
    backing: .buffered, defer: false)
  window.contentView = host
  window.orderFront(nil)
  defer { window.orderOut(nil) }
  try await Task.sleep(for: .milliseconds(100))
  host.layoutSubtreeIfNeeded()
  func scrollViews(_ view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
  }
  let scroll = try #require(scrollViews(host).first)
  let document = try #require(scroll.documentView)
  #expect(document.bounds.height > scroll.contentView.bounds.height)
  document.scroll(NSPoint(x: 0, y: document.bounds.maxY))
  #expect(document.visibleRect.maxY >= document.bounds.maxY - 1)
}
