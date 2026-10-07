import AppKit
import Combine
import LLMMeterCore

@MainActor
final class AppStore: ObservableObject {
  @Published private(set) var settings: AppSettings
  @Published private(set) var states: [ProviderID: ServiceState]
  @Published private(set) var message: String?
  @Published var now = Date()
  let storage: LocalStorage
  let coordinator: RefreshCoordinator
  private var eventTask: Task<Void, Never>?
  private var timer: Timer?
  private var settingsWritable = true
  private var cacheWritable = true
  private var sleeping = false
  private var observers: [NSObjectProtocol] = []

  init(storage: LocalStorage = LocalStorage(), provider: any UsageProvider = ProviderRegistry()) {
    self.storage = storage
    var settings = AppSettings()
    var snapshots: [UsageSnapshot] = []
    var errors: [String] = []
    do { settings = try storage.loadSettings() } catch {
      settingsWritable = false
      errors.append(error.localizedDescription)
    }
    do { snapshots = try storage.loadCache() } catch {
      cacheWritable = false
      errors.append(error.localizedDescription)
    }
    self.settings = settings
    states = Dictionary(
      uniqueKeysWithValues: ProviderID.allCases.map { id in
        (id, ServiceState(snapshot: snapshots.first { $0.provider == id }))
      })
    message = errors.isEmpty ? nil : errors.joined(separator: "\n")
    coordinator = RefreshCoordinator(settings: settings, snapshots: snapshots, provider: provider)
  }
  func start() {
    guard eventTask == nil else { return }
    let coordinator = coordinator
    eventTask = Task { [weak self] in
      for await event in coordinator.events {
        guard let self, !Task.isCancelled else { break }
        self.states[event.provider] = event.state
        // Bind the default metric once, after a verified reading, rather than following an account switch.
        if self.settings.showUsage, self.settings.selectedProvider == event.provider,
          self.settings.selectedAccountID == nil, event.state.confirmed,
          let snapshot = event.state.snapshot
        {
          self.change { settings in
            settings.selectedAccountID = snapshot.accountID
            if settings.selectedMetricID == "primary",
              !snapshot.metrics.contains(where: { $0.id == "primary" }),
              let first = snapshot.metrics.first
            {
              settings.selectedMetricID = first.id
            }
          }
        }
        if !event.state.refreshing && self.cacheWritable {
          do { try self.storage.saveCache(self.states.values.compactMap(\.snapshot)) } catch {
            self.message = error.localizedDescription
          }
        }
      }
    }
    timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, !self.sleeping else { return }
        self.now = Date()
        await self.coordinator.refresh()
      }
    }
    let center = NSWorkspace.shared.notificationCenter
    observers.append(
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor in
          self?.sleeping = true
          await self?.coordinator.suspend()
        }
      })
    observers.append(
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor in
          self?.sleeping = false
          self?.now = Date()
          await self?.coordinator.refresh()
        }
      })
    Task { await coordinator.refresh() }
  }
  func stop() {
    timer?.invalidate()
    timer = nil
    eventTask?.cancel()
    eventTask = nil
    for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    observers.removeAll()
    Task { await coordinator.suspend() }
  }
  var canEditSettings: Bool { settingsWritable }
  var refreshing: Bool { states.values.contains { $0.refreshing } }
  var visibleServices: [ServiceConfiguration] { settings.services.filter(\.visible) }
  func interval(_ id: ProviderID) -> TimeInterval {
    max(Double(settings.refreshMinutes * 60), id.minimumInterval)
  }
  func refresh(_ id: ProviderID? = nil, manual: Bool = true) {
    guard !sleeping else { return }
    Task { await coordinator.refresh(manual: manual, only: id) }
  }
  func change(_ edit: (inout AppSettings) -> Void) {
    guard settingsWritable else { return }
    var updated = settings
    edit(&updated)
    if updated.showUsage, updated.selectedAccountID == nil,
      states[updated.selectedProvider]?.confirmed == true,
      let snapshot = states[updated.selectedProvider]?.snapshot
    {
      updated.selectedAccountID = snapshot.accountID
      if !snapshot.metrics.contains(where: { $0.id == updated.selectedMetricID }),
        let first = snapshot.metrics.first
      {
        updated.selectedMetricID = first.id
      }
    }
    do { try storage.saveSettings(updated) } catch {
      message = error.localizedDescription
      return
    }
    settings = updated
    Task {
      await coordinator.update(updated)
      await coordinator.refresh()
    }
  }
  func editService(_ id: ProviderID, edit: (inout ServiceConfiguration) -> Void) {
    change { settings in
      guard let index = settings.services.firstIndex(where: { $0.provider == id }) else { return }
      let oldPath = settings.services[index].sourcePath
      edit(&settings.services[index])
      if oldPath != settings.services[index].sourcePath, settings.selectedProvider == id {
        settings.selectedAccountID = nil
      }
    }
  }
  func selectProvider(_ id: ProviderID) {
    change { settings in
      settings.selectedProvider = id
      let state = states[id]
      let snapshot = state?.confirmed == true ? state?.snapshot : nil
      settings.selectedAccountID = snapshot?.accountID
      settings.selectedMetricID = snapshot?.metrics.first?.id ?? "primary"
    }
  }
  func selectMetric(_ id: String) {
    change { settings in
      settings.selectedMetricID = id
      settings.selectedAccountID = states[settings.selectedProvider]?.snapshot?.accountID
    }
  }
  func move(_ id: ProviderID, by offset: Int) {
    change { settings in
      guard let index = settings.services.firstIndex(where: { $0.provider == id }),
        settings.services.indices.contains(index + offset)
      else { return }
      settings.services.swapAt(index, index + offset)
    }
  }
  func metric(_ id: ProviderID, period: MetricPeriod) -> UsageMetric? {
    states[id]?.snapshot?.metrics.first { $0.period == period && $0.scope == nil }
  }
  func label(_ id: ProviderID, period: MetricPeriod) -> String {
    guard settings.services.first(where: { $0.provider == id })?.enabled == true else { return "—" }
    return states[id]?.label(
      metric(id, period: period), now: now, interval: interval(id),
      remaining: settings.showRemaining) ?? "—"
  }
  var selectedMetric: UsageMetric? {
    guard let state = states[settings.selectedProvider], let snapshot = state.snapshot,
      state.confirmed, settings.selectedAccountID == snapshot.accountID
    else { return nil }
    return snapshot.metrics.first { $0.id == settings.selectedMetricID }
  }
  var menuBarLabel: String {
    guard settings.showUsage else { return "" }
    let id = settings.selectedProvider
    let enabled = settings.services.first { $0.provider == id }?.enabled == true
    let label =
      enabled
      ? states[id]?.label(
        selectedMetric, now: now, interval: interval(id),
        remaining: settings.showRemaining) ?? "—" : "—"
    return "\(id.abbreviation) \(label)\(settings.showRemaining && label != "—" ? " left" : "")"
  }
  var ringUsedPercent: Double? {
    guard settings.showUsage, let metric = selectedMetric,
      let state = states[settings.selectedProvider],
      settings.services.first(where: { $0.provider == settings.selectedProvider })?.enabled == true
    else { return nil }
    let freshness = state.freshness(metric, now: now, interval: interval(settings.selectedProvider))
    return freshness == .expired || freshness == .awaitingReset ? nil : metric.usedPercent
  }
  func tooltip(_ id: ProviderID) -> String {
    guard let state = states[id] else { return "Not read yet" }
    var lines = [id.name]
    if settings.services.first(where: { $0.provider == id })?.enabled == false {
      lines.append("Monitoring disabled")
    }
    if state.refreshing { lines.append("Refreshing…") }
    if let error = state.error { lines.append(error.localizedDescription) }
    if let snapshot = state.snapshot {
      lines.append(
        state.confirmed ? snapshot.accountLabel : "Previous account reading · awaiting confirmation"
      )
      if let plan = snapshot.plan { lines.append("Plan: \(plan)") }
      for metric in snapshot.metrics {
        let value =
          metric.percent(remaining: settings.showRemaining).map { String(format: "%.1f%%", $0) }
          ?? "Unknown"
        lines.append("\(metric.name): \(value) \(settings.showRemaining ? "remaining" : "used")")
        if let reset = metric.resetAt {
          lines.append(
            reset <= now
              ? "Awaiting update after reset"
              : "Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
        }
        lines.append("Read \(metric.readAt.formatted(date: .abbreviated, time: .shortened))")
      }
    } else if state.error == nil {
      lines.append("Not read yet")
    }
    if id == .antigravity {
      lines.append(
        "Model quotas are available in Settings. 5h/Weekly are unknown unless explicitly reported.")
    }
    return lines.joined(separator: "\n")
  }
}
