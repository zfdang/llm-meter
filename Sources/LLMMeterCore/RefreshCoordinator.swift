import Foundation

public struct RefreshEvent: Sendable {
  public let provider: ProviderID
  public let state: ServiceState
}

public actor RefreshCoordinator {
  private let provider: any UsageProvider
  private let clock: @Sendable () -> Date
  private let jitter: @Sendable () -> Double
  private var settings: AppSettings
  private var states: [ProviderID: ServiceState]
  private var tasks: [ProviderID: Task<Void, Never>] = [:]
  private var generations: [ProviderID: Int] = [:]
  private var attempts: [ProviderID: Date] = [:]
  private var failures: [ProviderID: Int] = [:]
  private var cooldowns: [ProviderID: Date] = [:]
  private var resetAttempts: [ProviderID: Set<String>] = [:]
  private let continuation: AsyncStream<RefreshEvent>.Continuation
  public nonisolated let events: AsyncStream<RefreshEvent>

  public init(
    settings: AppSettings, snapshots: [UsageSnapshot] = [],
    provider: any UsageProvider = ProviderRegistry(),
    clock: @escaping @Sendable () -> Date = { Date() },
    jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...0.1) }
  ) {
    self.settings = settings
    self.provider = provider
    self.clock = clock
    self.jitter = jitter
    states = Dictionary(
      uniqueKeysWithValues: ProviderID.allCases.map { id in
        (id, ServiceState(snapshot: snapshots.first { $0.provider == id }))
      })
    let pair = AsyncStream<RefreshEvent>.makeStream()
    events = pair.stream
    continuation = pair.continuation
  }
  public func update(_ settings: AppSettings) {
    let previous = self.settings
    self.settings = settings
    for configuration in settings.services {
      let old = previous.services.first { $0.provider == configuration.provider }
      if old != configuration || previous.active(configuration) != settings.active(configuration) {
        let id = configuration.provider
        generations[id, default: 0] += 1
        tasks[id]?.cancel()
        tasks[id] = nil
        var state = states[id] ?? ServiceState()
        state.refreshing = false
        if old?.sourcePath != configuration.sourcePath {
          state = ServiceState()
          attempts[id] = nil
          cooldowns[id] = nil
          failures[id] = nil
          resetAttempts[id] = nil
        }
        states[id] = state
        emit(id)
      }
    }
  }
  public func refresh(manual: Bool = false, only: ProviderID? = nil) {
    let now = clock()
    for configuration in settings.services {
      let id = configuration.provider
      guard only == nil || only == id, configuration.enabled,
        settings.active(configuration) || (manual && only == id), tasks[id] == nil
      else { continue }
      guard now >= (cooldowns[id] ?? .distantPast),
        now.timeIntervalSince(attempts[id] ?? .distantPast) >= id.manualInterval
      else { continue }
      var state = states[id] ?? ServiceState()
      let pendingResets = (state.snapshot?.metrics ?? []).compactMap { metric -> String? in
        guard let reset = metric.resetAt, reset <= now else { return nil }
        return "\(metric.id):\(reset.timeIntervalSince1970)"
      }.filter { !(resetAttempts[id] ?? []).contains($0) }
      guard manual || now >= state.nextRefresh || !pendingResets.isEmpty else { continue }
      resetAttempts[id, default: []].formUnion(pendingResets)
      attempts[id] = now
      state.refreshing = true
      states[id] = state
      emit(id)
      let generation = generations[id, default: 0]
      let fetcher = provider
      tasks[id] = Task {
        do {
          let snapshot = try await fetcher.fetch(configuration: configuration)
          self.finished(id, generation: generation, result: .success(snapshot))
        } catch {
          let failure = error as? MeterError ?? (error is CancellationError ? .cancelled : .network)
          self.finished(id, generation: generation, result: .failure(failure))
        }
      }
    }
  }
  public func suspend() {
    for id in ProviderID.allCases {
      generations[id, default: 0] += 1
      tasks[id]?.cancel()
      tasks[id] = nil
      states[id]?.refreshing = false
      emit(id)
    }
  }
  public func state(for id: ProviderID) -> ServiceState { states[id] ?? ServiceState() }
  private func finished(
    _ id: ProviderID, generation: Int, result: Result<UsageSnapshot, MeterError>
  ) {
    guard generations[id, default: 0] == generation else { return }
    tasks[id] = nil
    var state = states[id] ?? ServiceState()
    state.refreshing = false
    let now = clock()
    let interval = max(Double(settings.refreshMinutes * 60), id.minimumInterval)
    switch result {
    case .success(let snapshot):
      guard snapshot.provider == id else {
        state.error = .malformed("The source returned a mismatched provider.")
        state.nextRefresh = now.addingTimeInterval(interval)
        states[id] = state
        emit(id)
        return
      }
      state.snapshot = snapshot.merging(previous: state.snapshot)
      state.confirmed = true
      state.error = nil
      failures[id] = 0
      cooldowns[id] = nil
      state.nextRefresh = now.addingTimeInterval(interval * (1 + jitter()))
    case .failure(let error):
      state.error = error
      let count = min(failures[id, default: 0] + 1, 6)
      failures[id] = count
      var delay = min(1800, interval * pow(2, Double(count - 1))) * (1 + jitter())
      switch error {
      case .rateLimited(let retry): delay = max(retry, delay)
      case .authentication, .unsupported: delay = max(600, delay)
      default: break
      }
      if case .rateLimited = error {
        cooldowns[id] = now.addingTimeInterval(delay)
      } else {
        cooldowns[id] = nil
      }
      state.nextRefresh = now.addingTimeInterval(delay)
    }
    states[id] = state
    emit(id)
  }
  private func emit(_ id: ProviderID) {
    continuation.yield(.init(provider: id, state: states[id] ?? ServiceState()))
  }
}
