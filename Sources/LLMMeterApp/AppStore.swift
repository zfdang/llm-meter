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
  private var cacheDirty = false
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
  static func screenshotPreview(
    storage: LocalStorage, snapshots: [UsageSnapshot], now: Date
  ) -> AppStore {
    let store = AppStore(storage: storage)
    store.now = now
    store.states = Dictionary(
      uniqueKeysWithValues: snapshots.map { snapshot in
        var state = ServiceState(snapshot: snapshot)
        state.confirmed = true
        return (snapshot.provider, state)
      })
    store.settings.showUsage = true
    store.settings.selectedMetricID = "fiveHours"
    store.settings.selectedAccountID = snapshots.first { $0.provider == .codex }?.accountID
    store.cacheWritable = false
    return store
  }
  func start() {
    guard eventTask == nil else { return }
    let coordinator = coordinator
    eventTask = Task { [weak self] in
      for await event in coordinator.events {
        guard let self, !Task.isCancelled else { break }
        if self.states[event.provider]?.snapshot != event.state.snapshot { self.cacheDirty = true }
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
        // Coalesce a refresh batch into one write; errors without new data need none.
        if !self.refreshing { self.persistCacheIfNeeded() }
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
  func stop() async {
    persistCacheIfNeeded()
    timer?.invalidate()
    timer = nil
    eventTask?.cancel()
    eventTask = nil
    for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    observers.removeAll()
    await coordinator.suspend()
    await ProcessRunner.finishTerminationSignals()
  }
  private func persistCacheIfNeeded() {
    guard cacheWritable, cacheDirty else { return }
    do {
      try storage.saveCache(states.values.compactMap(\.snapshot))
      cacheDirty = false
    } catch { message = error.localizedDescription }
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
  func showProviderInMenuBar(_ id: ProviderID) {
    if settings.selectedProvider == id {
      // Preserve the selected metric when enabling usage mode for the same service.
      change { $0.showUsage = true }
    } else {
      change { settings in
        settings.showUsage = true
        settings.selectedProvider = id
        let state = states[id]
        let snapshot = state?.confirmed == true ? state?.snapshot : nil
        settings.selectedAccountID = snapshot?.accountID
        settings.selectedMetricID = snapshot?.metrics.first?.id ?? "primary"
      }
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
  func metric(_ id: ProviderID, period: MetricPeriod, scope: String? = nil) -> UsageMetric? {
    states[id]?.snapshot?.metrics.first { $0.period == period && $0.scope == scope }
  }
  func label(_ id: ProviderID, period: MetricPeriod, scope: String? = nil) -> String {
    guard settings.services.first(where: { $0.provider == id })?.enabled == true else { return "—" }
    return states[id]?.label(
      metric(id, period: period, scope: scope), now: now, interval: interval(id),
      remaining: settings.showRemaining) ?? "—"
  }
  func resetLabel(_ id: ProviderID, period: MetricPeriod, scope: String? = nil) -> String {
    guard settings.services.first(where: { $0.provider == id })?.enabled == true,
      let metric = metric(id, period: period, scope: scope)
    else { return "—" }
    return UsageDisplay.resetCountdown(metric.resetAt, now: now)
  }
  var antigravityPools: [String] {
    Set(
      states[.antigravity]?.snapshot?.metrics.compactMap { metric in
        metric.scope.flatMap { $0.hasPrefix("pool:") ? $0 : nil }
      } ?? []
    ).sorted()
  }
  var antigravityModels: [UsageMetric] {
    states[.antigravity]?.snapshot?.metrics.filter { $0.scope?.hasPrefix("pool:") != true } ?? []
  }
  func modelLabel(_ metric: UsageMetric) -> String {
    metricLabel(.antigravity, metric: metric)
  }
  func metricLabel(_ id: ProviderID, metric: UsageMetric) -> String {
    guard settings.services.first(where: { $0.provider == id })?.enabled == true else {
      return "—"
    }
    return states[id]?.label(
      metric, now: now, interval: interval(id), remaining: settings.showRemaining) ?? "—"
  }
  var copilotMetrics: [UsageMetric] { states[.copilot]?.snapshot?.metrics ?? [] }
  func countLabel(_ metric: UsageMetric) -> String {
    guard !metric.unlimited, let limit = metric.limit, let remaining = metric.remaining,
      let unit = metric.unit
    else { return "Monthly allowance" }
    let amount = settings.showRemaining ? remaining : max(0, limit - remaining)
    return
      "\(amount.formatted(.number.precision(.fractionLength(0...1)))) / \(limit.formatted(.number.precision(.fractionLength(0...1)))) \(unit)"
  }
  func updateLabel(_ id: ProviderID) -> String {
    guard settings.services.first(where: { $0.provider == id })?.enabled == true else {
      return "Monitoring off"
    }
    guard let state = states[id] else { return "Not read yet" }
    if state.refreshing { return "Refreshing…" }
    if let snapshot = state.snapshot {
      return UsageDisplay.updateAge(snapshot.readAt, now: now)
    }
    return state.error == nil ? "Not read yet" : "Unable to refresh"
  }
  var panelUpdateLabel: String {
    let services = visibleServices.filter(\.enabled)
    if services.contains(where: { states[$0.provider]?.refreshing == true }) {
      return "Refreshing…"
    }
    guard let latest = services.compactMap({ states[$0.provider]?.snapshot?.readAt }).max() else {
      return "Not updated yet"
    }
    return UsageDisplay.updateAge(latest, now: now)
  }
  var panelUpdateDetails: String {
    "Most recent successful read among visible enabled services.\n"
      + visibleServices.map { "\($0.provider.name): \(updateLabel($0.provider))" }.joined(
        separator: "\n")
  }
  func serviceStatusLabel(_ id: ProviderID) -> String? {
    guard settings.services.first(where: { $0.provider == id })?.enabled == true else {
      return "Monitoring off"
    }
    guard let state = states[id] else { return "Not read yet" }
    if state.refreshing { return "Refreshing…" }
    if state.error != nil { return "Unable to refresh" }
    return state.snapshot == nil ? "Not read yet" : nil
  }
  var selectedMetric: UsageMetric? {
    guard let state = states[settings.selectedProvider], let snapshot = state.snapshot,
      state.confirmed, settings.selectedAccountID == snapshot.accountID
    else { return nil }
    return snapshot.metrics.first { $0.id == settings.selectedMetricID }
  }
  var menuBarValue: String {
    guard settings.showUsage else { return "" }
    let id = settings.selectedProvider
    let enabled = settings.services.first { $0.provider == id }?.enabled == true
    let label =
      enabled
      ? states[id]?.label(
        selectedMetric, now: now, interval: interval(id),
        remaining: settings.showRemaining) ?? "—" : "—"
    return
      "\(label)\(settings.showRemaining && label != "—" && selectedMetric?.unlimited != true ? " left" : "")"
  }
  var menuBarLabel: String {
    settings.showUsage ? "\(settings.selectedProvider.name) \(menuBarValue)" : "LLM Meter"
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
        lines.append(
          metric.unlimited
            ? "\(metric.name): Unlimited"
            : "\(metric.name): \(value) \(settings.showRemaining ? "remaining" : "used")")
        if metric.unit != nil { lines.append(countLabel(metric)) }
        if let reset = metric.resetAt {
          lines.append(
            reset <= now
              ? "Awaiting update after reset"
              : "\(UsageDisplay.resetCountdown(reset, now: now)) · \(reset.formatted(date: .abbreviated, time: .shortened))"
          )
        }
        if metric.pendingConfirmation { lines.append("Retained reading · awaiting confirmation") }
        lines.append(UsageDisplay.updateAge(metric.readAt, now: now))
        lines.append("Read \(metric.readAt.formatted(date: .abbreviated, time: .shortened))")
      }
    } else if state.error == nil {
      lines.append("Not read yet")
    }
    if id == .antigravity {
      lines.append(
        "Quota groups are shown separately. Model quotas have no assumed window duration.")
    }
    return lines.joined(separator: "\n")
  }
}
