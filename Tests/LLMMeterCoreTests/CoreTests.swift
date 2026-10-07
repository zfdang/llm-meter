import Foundation
import Testing

@testable import LLMMeterCore

private let instant = Date(timeIntervalSince1970: 1_790_000_000)

@Test func displayTimesDistinguishUnknownPassedAndUpcomingResets() {
  #expect(UsageDisplay.resetCountdown(.distantFuture, now: instant) == "Resets in 999d+")
  #expect(UsageDisplay.resetCountdown(nil, now: instant) == "Reset unknown")
  #expect(UsageDisplay.resetCountdown(instant, now: instant) == "Awaiting update")
  #expect(
    UsageDisplay.resetCountdown(instant.addingTimeInterval(-60), now: instant)
      == "Awaiting update")
  #expect(
    UsageDisplay.resetCountdown(instant.addingTimeInterval(59), now: instant) == "Resets <1m")
  #expect(
    UsageDisplay.resetCountdown(instant.addingTimeInterval(3660), now: instant)
      == "Resets in 1h 1m")
  #expect(
    UsageDisplay.resetCountdown(instant.addingTimeInterval(90_000), now: instant)
      == "Resets in 1d 1h")
  #expect(
    UsageDisplay.updateAge(instant.addingTimeInterval(60), now: instant) == "Updated just now")
  #expect(
    UsageDisplay.updateAge(instant.addingTimeInterval(-60), now: instant) == "Updated 1m ago")
  #expect(
    UsageDisplay.updateAge(instant.addingTimeInterval(-7200), now: instant) == "Updated 2h 0m ago")
}

private func reading(
  provider: ProviderID = .codex, account: String = "account-a", used: Double = 42
) -> UsageSnapshot {
  .init(
    provider: provider, accountID: account, accountLabel: "Current account",
    metrics: [
      .init(id: "primary", name: "5h", period: .fiveHours, usedPercent: used, readAt: instant)
    ], readAt: instant)
}

@Test func codexPreservesUnknownOverageAndResetAnchor() throws {
  let data = Data(
    #"{"rate_limit":{"primary_window":{"used_percent":105,"limit_window_seconds":18000,"reset_after_seconds":120},"secondary_window":{"limit_window_seconds":604800}}}"#
      .utf8)
  let snapshot = try UsageParsers.codex(
    data, accountID: "a", accountLabel: "Current account", now: instant)
  #expect(snapshot.metrics[0].percent(remaining: false) == 105)
  #expect(snapshot.metrics[0].percent(remaining: true) == 0)
  #expect(snapshot.metrics[0].resetAt == instant.addingTimeInterval(120))
  #expect(snapshot.metrics[1].period == .weekly)
  #expect(snapshot.metrics[1].usedPercent == nil)
  #expect(throws: MeterError.self) {
    try UsageParsers.codex(
      Data(#"{"rate_limit":{"primary_window":{"used_percent":-1}}}"#.utf8), accountID: "a",
      accountLabel: "a", now: instant)
  }
}

@Test func claudeDistinguishesModelWindowsAndPartialUpdates() throws {
  let snapshot = try UsageParsers.claude(
    """
    Current session: 13% used · resets Oct 9 at 3:30pm (Asia/Singapore)
    Current week (all models): 4% used
    Current week (Sonnet only): 8% used
    """, accountID: "a", accountLabel: "a", now: instant)
  #expect(snapshot.complete == false)
  #expect(snapshot.metrics.count == 3)
  #expect(snapshot.metrics.filter { $0.scope == nil }.count == 2)
  let partial = try UsageParsers.claude(
    "Current session: 20% used", accountID: "a", accountLabel: "a",
    now: instant.addingTimeInterval(60))
  let merged = partial.merging(previous: snapshot)
  #expect(merged.metrics.count == 3)
  #expect(merged.metrics.first { $0.id == "week" }?.readAt == instant)
  #expect(merged.metrics.first { $0.id == "week" }?.pendingConfirmation == true)
  #expect(partial.merging(previous: reading(account: "other")).metrics.count == 1)
  #expect(throws: MeterError.self) {
    try UsageParsers.claude(
      "Current session: 20% used\nNot signed in", accountID: "a", accountLabel: "a", now: instant)
  }
  #expect(throws: MeterError.self) {
    try UsageParsers.claude(
      "You are currently using your subscription", accountID: "a", accountLabel: "a", now: instant)
  }
}

@Test func resetDatesHandleYearBoundaryAndTimeZones() throws {
  let now = try #require(UsageParsers.isoDate("2026-12-31T20:00:00Z"))
  #expect(
    UsageParsers.resetDate("Jan 2 at 3:30pm (Asia/Singapore)", now: now)
      == UsageParsers.isoDate("2027-01-02T07:30:00Z"))
  #expect(
    UsageParsers.resetDate("Oct 9, 2:59pm (UTC)", now: instant)
      == UsageParsers.isoDate("2026-10-09T14:59:00Z"))
  #expect(UsageParsers.resetDate("Oct 9 at 3pm (Invalid/Zone)", now: instant) == nil)
}

@Test func antigravityDoesNotInventPeriodsOrMissingFractions() throws {
  let data = Data(
    #"{"models":{"gemini-pro":{"displayName":"Gemini Pro","quotaInfo":{"remainingFraction":0.25,"resetTime":"2026-10-09T12:00:00Z"}},"claude-sonnet":{"quotaInfo":{"resetTime":"2026-10-09T12:00:00Z"}},"tab_test":{"quotaInfo":{"remainingFraction":1}},"disabled":{"disabled":true,"quotaInfo":{"remainingFraction":1}}}}"#
      .utf8)
  let snapshot = try UsageParsers.antigravity(data, accountID: "a", accountLabel: "a", now: instant)
  #expect(snapshot.metrics.count == 2)
  #expect(snapshot.metrics.allSatisfy { $0.period == .other && $0.scope != nil })
  #expect(snapshot.metrics.first { $0.id == "gemini-pro" }?.usedPercent == 75)
  #expect(snapshot.metrics.first { $0.id == "claude-sonnet" }?.usedPercent == nil)
  #expect(throws: MeterError.self) {
    try UsageParsers.antigravity(
      Data(#"{"models":{"m":{"quotaInfo":{"remainingFraction":2}}}}"#.utf8), accountID: "a",
      accountLabel: "a", now: instant)
  }
}

@Test func staleAndResetStatesNeverPretendZero() {
  var state = ServiceState(snapshot: reading())
  state.confirmed = true
  let metric = state.snapshot!.metrics[0]
  #expect(state.label(metric, now: instant, interval: 180, remaining: false) == "42%")
  state.error = .network
  #expect(state.label(metric, now: instant, interval: 180, remaining: true) == "58%·")
  #expect(
    state.label(metric, now: instant.addingTimeInterval(1800), interval: 180, remaining: false)
      == "—")
  var reset = metric
  reset.resetAt = instant
  #expect(state.label(reset, now: instant, interval: 180, remaining: false) == "—")
  #expect(state.label(nil, now: instant, interval: 180, remaining: false) == "—")
}

@Test func storagePreservesCorruptAndNewerFilesAndUsesPrivatePermissions() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let storage = LocalStorage(directory: directory)
  try storage.saveSettings(AppSettings())
  #expect(try storage.loadSettings() == AppSettings())
  let permission =
    try FileManager.default.attributesOfItem(
      atPath: directory.appendingPathComponent("settings.json").path)[.posixPermissions]
    as? NSNumber
  #expect(permission?.intValue == 0o600)
  try storage.saveCache([reading()])
  #expect(try storage.loadCache() == [reading()])
  let source = directory.appendingPathComponent("settings.json")
  let corrupt = Data("{invalid".utf8)
  try corrupt.write(to: source)
  #expect(throws: MeterError.self) { try storage.loadSettings() }
  #expect(try Data(contentsOf: source) == corrupt)
  var newer = AppSettings()
  newer.schemaVersion = 2
  let data = try JSONEncoder().encode(newer)
  try data.write(to: source)
  #expect(throws: MeterError.self) { try storage.loadSettings() }
  #expect(try Data(contentsOf: source) == data)
}

@Test func visibilityAndMonitoringAreIndependent() {
  var settings = AppSettings()
  var configuration = ServiceConfiguration(provider: .codex)
  configuration.visible = false
  #expect(!settings.active(configuration))
  settings.showUsage = true
  #expect(settings.active(configuration))
  configuration.enabled = false
  #expect(!settings.active(configuration))
}

private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = instant
  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  func advance(_ seconds: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    value = value.addingTimeInterval(seconds)
  }
}
private actor ControlledProvider: UsageProvider {
  private var waiting: [CheckedContinuation<UsageSnapshot, any Error>] = []
  private(set) var count = 0
  func fetch(configuration: ServiceConfiguration) async throws -> UsageSnapshot {
    count += 1
    return try await withCheckedThrowingContinuation { waiting.append($0) }
  }
  func succeed(_ snapshot: UsageSnapshot = reading()) {
    waiting.removeFirst().resume(returning: snapshot)
  }
  func fail(_ error: MeterError) { waiting.removeFirst().resume(throwing: error) }
}
private func settle(_ condition: () async -> Bool) async throws {
  for _ in 0..<200 {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  Issue.record("Asynchronous condition did not settle")
  throw MeterError.timeout
}
private func codexOnly() -> AppSettings {
  var settings = AppSettings()
  for index in settings.services.indices {
    settings.services[index].enabled = settings.services[index].provider == .codex
  }
  return settings
}

@Test func refreshCoalescesRequestsAndRespectsCooldown() async throws {
  let source = ControlledProvider()
  let clock = TestClock()
  let coordinator = RefreshCoordinator(
    settings: codexOnly(), provider: source, clock: { clock.now() }, jitter: { 0 })
  await coordinator.refresh(manual: true)
  await coordinator.refresh(manual: true)
  try await settle { await source.count == 1 }
  await source.fail(.rateLimited(600))
  try await settle { !(await coordinator.state(for: .codex)).refreshing }
  clock.advance(599)
  await coordinator.refresh(manual: true)
  #expect(await source.count == 1)
  clock.advance(1)
  await coordinator.refresh(manual: true)
  try await settle { await source.count == 2 }
  await source.succeed()
  try await settle { (await coordinator.state(for: .codex)).confirmed }
}

@Test func targetedRefreshCanReadHiddenButNeverDisabledSources() async throws {
  let source = ControlledProvider()
  var settings = codexOnly()
  settings.services[0].visible = false
  let coordinator = RefreshCoordinator(settings: settings, provider: source)
  await coordinator.refresh()
  await coordinator.refresh(manual: true)
  #expect(await source.count == 0)
  await coordinator.refresh(manual: true, only: .codex)
  try await settle { await source.count == 1 }
  await source.succeed()
  try await settle { !(await coordinator.state(for: .codex)).refreshing }
  settings.services[0].enabled = false
  await coordinator.update(settings)
  await coordinator.refresh(manual: true, only: .codex)
  #expect(await source.count == 1)
}

@Test func lateResponseCannotRestoreChangedSource() async throws {
  let source = ControlledProvider()
  let clock = TestClock()
  var settings = codexOnly()
  let coordinator = RefreshCoordinator(
    settings: settings, provider: source, clock: { clock.now() }, jitter: { 0 })
  await coordinator.refresh()
  try await settle { await source.count == 1 }
  settings.services[0].sourcePath = "/another/auth.json"
  await coordinator.update(settings)
  await coordinator.refresh()
  try await settle { await source.count == 2 }
  await source.succeed(reading(account: "old"))
  try await Task.sleep(for: .milliseconds(20))
  #expect(await coordinator.state(for: .codex).snapshot == nil)
  await source.succeed(reading(account: "new"))
  try await settle { await coordinator.state(for: .codex).snapshot?.accountID == "new" }
}

@Test func failuresRetainSnapshotAndResetTriggersOnlyOnce() async throws {
  let source = ControlledProvider()
  let clock = TestClock()
  var snapshot = reading()
  snapshot.metrics[0].resetAt = instant.addingTimeInterval(20)
  let coordinator = RefreshCoordinator(
    settings: codexOnly(), snapshots: [snapshot], provider: source, clock: { clock.now() },
    jitter: { 0 })
  await coordinator.refresh()
  try await settle { await source.count == 1 }
  await source.succeed(snapshot)
  try await settle { !(await coordinator.state(for: .codex)).refreshing }
  clock.advance(20)
  await coordinator.refresh()
  try await settle { await source.count == 2 }
  await source.fail(.network)
  try await settle { !(await coordinator.state(for: .codex)).refreshing }
  #expect(await coordinator.state(for: .codex).snapshot == snapshot)
  await coordinator.refresh()
  #expect(await source.count == 2)
}

private actor FixtureTransport: HTTPTransport {
  private(set) var requests: [URLRequest] = []
  var responses: [Data]
  init(_ responses: [String]) { self.responses = responses.map { Data($0.utf8) } }
  func data(for request: URLRequest) async throws -> Data {
    requests.append(request)
    guard !responses.isEmpty else { throw MeterError.unsupported("Fixture endpoint unavailable") }
    return responses.removeFirst()
  }
}
@Test func codexAdapterReadsButDoesNotWriteCredentials() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let path = directory.appendingPathComponent("auth.json")
  let data = Data(
    #"{"auth_mode":"chatgpt","tokens":{"account_id":"account","access_token":"fixture-token"}}"#
      .utf8)
  try data.write(to: path)
  let network = FixtureTransport([
    #"{"rate_limit":{"primary_window":{"used_percent":42,"limit_window_seconds":18000}}}"#
  ])
  let snapshot = try await CodexProvider(network: network).fetch(
    configuration: .init(provider: .codex, sourcePath: path.path))
  #expect(snapshot.metrics[0].usedPercent == 42)
  #expect(try Data(contentsOf: path) == data)
  let requests = await network.requests
  #expect(requests[0].value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account")
  #expect(snapshot.accountID != "account")
}

@Test func antigravityAdapterVerifiesIdentityAndPreservesSource() async throws {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: path) }
  let data = Data(
    #"{"type":"antigravity","token":{"access_token":"fixture","project_id":"project"}}"#.utf8)
  try data.write(to: path)
  let network = FixtureTransport([
    #"{"id":"google-account","email":"a@example.com"}"#,
    #"{"models":{"gemini":{"quotaInfo":{"remainingFraction":0.25}}}}"#,
    #"{"groups":[{"displayName":"Gemini","buckets":[{"window":"5h","remainingFraction":0.5},{"window":"weekly","remainingFraction":0.8}]}]}"#,
  ])
  let snapshot = try await AntigravityProvider(network: network).fetch(
    configuration: .init(provider: .antigravity, sourcePath: path.path))
  #expect(snapshot.metrics[0].usedPercent == 75)
  #expect(snapshot.accountLabel == "a•••@example.com")
  #expect(try Data(contentsOf: path) == data)
  #expect(await network.requests.count == 3)
  #expect(snapshot.metrics.count == 3)
  #expect(snapshot.metrics[2].period == .weekly)
}

@Test func claudeVersionGatePreventsUnsupportedPrintCommands() {
  #expect(!ClaudeProvider.supportsUsage("2.1.284 (Claude Code)"))
  #expect(ClaudeProvider.supportsUsage("2.1.289 (Claude Code)"))
  #expect(!ClaudeProvider.supportsUsage("unknown"))
}

@Test func processRunnerBoundsOutputAndTerminatesTimeouts() async throws {
  let runner = ProcessRunner()
  let result = try await runner.run(executable: "/usr/bin/printf", arguments: ["usage"], timeout: 2)
  #expect(String(decoding: result.output, as: UTF8.self) == "usage")
  await #expect(throws: MeterError.self) {
    try await runner.run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.1)
  }
  await #expect(throws: MeterError.self) {
    try await runner.run(executable: "/usr/bin/yes", arguments: [], timeout: 5)
  }
}

private actor ClaudeFixtureCommands: CommandRunning {
  private var identities = 0
  private(set) var usageArguments: [String] = []
  let switchAccount: Bool
  init(switchAccount: Bool = false) { self.switchAccount = switchAccount }
  func run(executable: String, arguments: [String], timeout: TimeInterval) async throws
    -> CommandResult
  {
    if arguments == ["--version"] {
      return .init(output: Data("2.1.289 (Claude Code)".utf8), status: 0)
    }
    if arguments.first == "auth" {
      identities += 1
      let email = switchAccount && identities > 1 ? "b@example.com" : "a@example.com"
      return .init(
        output: try JSONSerialization.data(withJSONObject: [
          "loggedIn": true, "email": email, "authMethod": "claude.ai",
        ]), status: 0)
    }
    usageArguments = arguments
    return .init(
      output: Data("Current session: 10% used\nCurrent week (all models): 20% used".utf8), status: 0
    )
  }
}
@Test func claudeAdapterUsesReadOnlyCommandAndRejectsAccountChanges() async throws {
  let commands = ClaudeFixtureCommands()
  let configuration = ServiceConfiguration(provider: .claude, sourcePath: "/usr/bin/printf")
  let snapshot = try await ClaudeProvider(commands: commands).fetch(configuration: configuration)
  #expect(snapshot.metrics.count == 2)
  #expect(snapshot.accountLabel == "a•••@example.com")
  let arguments = await commands.usageArguments
  #expect(arguments.contains("/usage"))
  #expect(arguments.contains("--no-session-persistence"))
  #expect(arguments.contains("{\"disableAllHooks\":true}"))
  let changing = ClaudeFixtureCommands(switchAccount: true)
  await #expect(throws: MeterError.self) {
    try await ClaudeProvider(commands: changing).fetch(configuration: configuration)
  }
}

@Test func cancellingRunnerStopsSubprocessPromptly() async throws {
  let runner = ProcessRunner()
  let start = Date()
  let task = Task { try await runner.run(executable: "/bin/sleep", arguments: ["10"], timeout: 20) }
  try await Task.sleep(for: .milliseconds(50))
  task.cancel()
  do {
    _ = try await task.value
    Issue.record("Cancelled process unexpectedly succeeded")
  } catch {}
  #expect(Date().timeIntervalSince(start) < 2)
}
