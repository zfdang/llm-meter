import AppKit
import LLMMeterCore
import SwiftUI

@MainActor
enum ScreenshotExporter {
  static func export(to output: URL, dark: Bool = false) throws {
    // Render the actual native view with fictional data and isolated storage.
    // Do not start scheduling, query providers, or read the user's settings.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let readAt = now.addingTimeInterval(-180)
    func metric(
      _ id: String, _ name: String, _ period: MetricPeriod, _ used: Double,
      reset: TimeInterval, scope: String? = nil
    ) -> UsageMetric {
      .init(
        id: id, name: name, period: period, scope: scope, usedPercent: used,
        resetAt: now.addingTimeInterval(reset), readAt: readAt)
    }
    func snapshot(_ provider: ProviderID, _ metrics: [UsageMetric]) -> UsageSnapshot {
      .init(
        provider: provider, accountID: "preview-\(provider.rawValue)", accountLabel: "Demo account",
        metrics: metrics, readAt: readAt)
    }
    let snapshots = [
      snapshot(
        .codex,
        [
          metric("fiveHours", "5h", .fiveHours, 72, reset: 7_200),
          metric("weekly", "Weekly", .weekly, 43, reset: 259_200),
        ]),
      snapshot(
        .claude,
        [
          metric("fiveHours", "5h", .fiveHours, 36, reset: 10_800),
          metric("weekly", "Weekly", .weekly, 81, reset: 345_600),
        ]),
      snapshot(
        .antigravity,
        [
          metric(
            "claude-5h", "5h", .fiveHours, 84, reset: 7_200, scope: "pool:Claude and GPT models"),
          metric(
            "claude-week", "Weekly", .weekly, 62, reset: 432_000,
            scope: "pool:Claude and GPT models"),
          metric("gemini-5h", "5h", .fiveHours, 12, reset: 14_400, scope: "pool:Gemini Models"),
          metric("gemini-week", "Weekly", .weekly, 24, reset: 172_800, scope: "pool:Gemini Models"),
        ]),
      snapshot(
        .copilot,
        [
          .init(
            id: "premium_interactions", name: "AI Credits", period: .monthly, usedPercent: 18,
            resetAt: now.addingTimeInterval(1_036_800), readAt: readAt,
            unit: "AI credits", limit: 1_500, remaining: 1_230),
          .init(
            id: "chat", name: "Chat requests", period: .monthly, usedPercent: nil, readAt: readAt,
            unlimited: true),
          .init(
            id: "completions", name: "Completions", period: .monthly, usedPercent: nil,
            readAt: readAt, unlimited: true),
        ]),
    ]
    let store = AppStore.screenshotPreview(
      storage: LocalStorage(directory: directory), snapshots: snapshots, now: now)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let view = NSHostingView(
      rootView: VStack(spacing: 14) {
        HStack(spacing: 6) {
          Image(nsImage: ProviderIcon.image(.codex))
          Text(store.menuBarValue).font(.system(size: 12)).monospacedDigit()
        }.padding(.horizontal, 12).padding(.vertical, 6)
          .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
        UsagePanel(store: store, maximumContentHeight: { 700 }, openSettings: {})
          .background(Color(nsColor: .windowBackgroundColor))
          .clipShape(RoundedRectangle(cornerRadius: 12))
      }.padding(20).background(Color(nsColor: .underPageBackgroundColor))
        .environment(\.colorScheme, dark ? .dark : .light))
    let size = view.fittingSize
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.contentView = view
    view.frame = NSRect(origin: .zero, size: size)
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw MeterError.storage("Could not render the screenshot.")
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw MeterError.storage("Could not encode the screenshot.")
    }
    try FileManager.default.createDirectory(
      at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png.write(to: output)
  }
}
