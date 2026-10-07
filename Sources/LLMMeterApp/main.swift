import AppKit
import Combine
import Darwin
import LLMMeterCore
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
  let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  let popover = NSPopover()
  let store: AppStore
  var window: NSWindow?
  private var subscriptions: Set<AnyCancellable> = []
  init(store: AppStore) {
    self.store = store
    super.init()
    item.button?.target = self
    item.button?.action = #selector(toggle)
    popover.behavior = .transient
    popover.contentViewController = NSHostingController(
      rootView: UsagePanel(store: store) { [weak self] in self?.showSettings() })
    store.objectWillChange.sink { [weak self] in
      Task { @MainActor in self?.render() }
    }.store(in: &subscriptions)
    render()
  }
  func render() {
    item.button?.image =
      store.settings.showUsage ? ProviderIcon.image(store.settings.selectedProvider) : Self.icon()
    item.button?.imagePosition = store.settings.showUsage ? .imageLeading : .imageOnly
    item.button?.title = store.settings.showUsage ? " " + store.menuBarValue : ""
    item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    item.button?.toolTip =
      store.settings.showUsage
      ? store.tooltip(store.settings.selectedProvider) : "LLM Meter · Click to view usage"
    item.button?.setAccessibilityLabel(store.settings.showUsage ? store.menuBarLabel : "LLM Meter")
  }
  static func icon(size: CGFloat = 18, color: NSColor = .black) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
      color.setStroke()
      let center = NSPoint(x: size * 0.5, y: size * 0.43)
      let arc = NSBezierPath()
      arc.appendArc(
        withCenter: center, radius: size * 0.37, startAngle: 210,
        endAngle: -30, clockwise: true)
      arc.lineWidth = size * 0.09
      arc.lineCapStyle = .round
      arc.stroke()
      let needle = NSBezierPath()
      needle.move(to: center)
      needle.line(to: NSPoint(x: size * 0.69, y: size * 0.64))
      needle.lineWidth = size * 0.09
      needle.lineCapStyle = .round
      needle.stroke()
      color.setFill()
      NSBezierPath(
        ovalIn: NSRect(x: size * 0.425, y: size * 0.355, width: size * 0.15, height: size * 0.15)
      ).fill()
      return true
    }
    image.isTemplate = true
    return image
  }
  @objc func toggle() {
    if popover.isShown {
      popover.performClose(nil)
    } else if let button = item.button {
      render()
      store.refresh(manual: false)
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
  }
  func showSettings() {
    popover.performClose(nil)
    if window == nil {
      let controller = NSHostingController(rootView: SettingsView(store: store))
      let window = NSWindow(contentViewController: controller)
      window.title = "LLM Meter Settings"
      window.styleMask = [.titled, .closable, .miniaturizable]
      window.isReleasedWhenClosed = false
      window.center()
      self.window = window
    }
    NSApplication.shared.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var controller: MenuBarController?
  var store: AppStore?
  func applicationDidFinishLaunching(_ notification: Notification) {
    let peers = NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.zfdang.llm-meter"
    )
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if let existing = peers.first {
      existing.activate(options: [.activateIgnoringOtherApps])
      NSApplication.shared.terminate(nil)
      return
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    let menu = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    let settingsItem = appMenu.addItem(
      withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
    settingsItem.target = self
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Quit LLM Meter", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    appItem.submenu = appMenu
    menu.addItem(appItem)
    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(
      withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowItem.submenu = windowMenu
    menu.addItem(windowItem)
    NSApplication.shared.mainMenu = menu
    let store = AppStore()
    self.store = store
    controller = MenuBarController(store: store)
    store.start()
    if ProcessInfo.processInfo.arguments.contains("--settings") { controller?.showSettings() }
    if ProcessInfo.processInfo.arguments.contains("--panel") { controller?.toggle() }
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if controller?.window?.isVisible == true {
      controller?.window?.makeKeyAndOrderFront(nil)
    } else if controller?.popover.isShown == false {
      controller?.toggle()
    }
    return true
  }
  @objc func openSettings() { controller?.showSettings() }
  func applicationWillTerminate(_ notification: Notification) { store?.stop() }
}

let arguments = CommandLine.arguments
if arguments.contains("--diagnose") {
  Task {
    let provider = ProviderRegistry()
    let settings = (try? LocalStorage().loadSettings()) ?? AppSettings()
    for service in settings.services where service.enabled {
      do {
        let snapshot = try await provider.fetch(configuration: service)
        print("\(service.provider.name): OK (\(snapshot.metrics.count) metrics)")
      } catch { print("\(service.provider.name): \(error.localizedDescription)") }
    }
    exit(0)
  }
  dispatchMain()
} else if let index = arguments.firstIndex(of: "--export-icon"),
  arguments.indices.contains(index + 1)
{
  let size = 1024
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSColor(calibratedRed: 0.12, green: 0.25, blue: 0.40, alpha: 1).setFill()
  NSBezierPath(
    roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 210, yRadius: 210
  ).fill()
  let symbol = MenuBarController.icon(size: 640, color: .white)
  symbol.isTemplate = false
  symbol.draw(in: NSRect(x: 192, y: 192, width: 640, height: 640))
  NSGraphicsContext.restoreGraphicsState()
  try rep.representation(using: .png, properties: [:])!.write(
    to: URL(fileURLWithPath: arguments[index + 1]))
} else {
  let application = NSApplication.shared
  let delegate = AppDelegate()
  application.delegate = delegate
  application.run()
}
