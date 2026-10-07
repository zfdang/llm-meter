import Foundation
import Testing

@testable import LLMMeterCore

private let quota =
  #"{"copilot_plan":"individual","token_based_billing":true,"quota_reset_date_utc":"2026-11-01T00:00:00Z","quota_snapshots":{"premium_interactions":{"entitlement":"1500","quota_remaining":"1125","unlimited":false,"has_quota":false},"chat":{"unlimited":true},"completions":{"unlimited":true}}}"#

@Test func copilotSeparatesMonthlyCreditsUnlimitedAndUnknownQuotas() throws {
  let now = Date(timeIntervalSince1970: 1_790_000_000)
  let snapshot = try CopilotParser.parse(
    Data(quota.utf8), accountID: "a", accountLabel: "Account", now: now)
  #expect(snapshot.metrics.count == 3)
  #expect(snapshot.metrics[0].name == "AI Credits")
  #expect(snapshot.metrics[0].unit == "AI credits")
  #expect(snapshot.metrics[0].usedPercent == 25)
  #expect(snapshot.metrics[0].limit == 1500)
  #expect(snapshot.metrics[0].remaining == 1125)
  #expect(snapshot.metrics.allSatisfy { $0.period == .monthly })
  #expect(snapshot.metrics[0].resetAt == UsageParsers.isoDate("2026-11-01T00:00:00Z"))
  #expect(snapshot.metrics[1].unlimited)
  #expect(snapshot.metrics[1].percent(remaining: false) == nil)
  var state = ServiceState(snapshot: snapshot)
  state.confirmed = true
  #expect(
    state.label(snapshot.metrics[1], now: now, interval: 180, remaining: false) == "Unlimited")
  let unknown = try CopilotParser.parse(
    Data(
      #"{"quota_snapshots":{"premium_interactions":{"entitlement":"many","unlimited":false}}}"#.utf8
    ), accountID: "a", accountLabel: "Account", now: now)
  #expect(unknown.metrics[0].name == "Premium requests")
  #expect(unknown.metrics[0].usedPercent == nil)
  #expect(!unknown.metrics[0].unlimited)
  let unavailable = try CopilotParser.parse(
    Data(
      #"{"quota_snapshots":{"premium_interactions":{"unlimited":true,"has_quota":false}}}"#.utf8),
    accountID: "a", accountLabel: "Account", now: now)
  #expect(!unavailable.metrics[0].unlimited)
  #expect(unavailable.metrics[0].usedPercent == nil)
}

private actor CopilotFallbackTransport: HTTPTransport {
  var reads = 0
  func data(for request: URLRequest) async throws -> Data {
    reads += 1
    if request.value(forHTTPHeaderField: "Authorization") == "token expired" {
      throw MeterError.authentication("Expired fixture")
    }
    #expect(request.value(forHTTPHeaderField: "Authorization") == "token fixture")
    return request.url?.path == "/user"
      ? Data(#"{"id":123,"login":"octocat"}"#.utf8) : Data(quota.utf8)
  }
}

@Test func copilotTriesAnotherExistingTokenForTheSameAccount() async throws {
  let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: source) }
  let data = Data(
    #"{"github.com:a":{"user":"octocat","oauth_token":"expired"},"github.com:b":{"user":"octocat","oauth_token":"fixture"}}"#
      .utf8)
  try data.write(to: source)
  let network = CopilotFallbackTransport()
  let snapshot = try await CopilotProvider(network: network).fetch(
    configuration: .init(provider: .copilot, sourcePath: source.path))
  #expect(snapshot.metrics.count == 3)
  #expect(await network.reads == 3)
  #expect(try Data(contentsOf: source) == data)
}

@Test func copilotJSONCPreservesQuotedContentAndRejectsUnclosedComments() throws {
  let data = Data(
    #"{/* comment */ "oauth_token":"x//y/*z*/,}", "array":[1,2,], // line comment"#.appending("\n}")
      .utf8)
  let parsed =
    try JSONSerialization.jsonObject(with: CopilotProvider.jsonData(data)) as! [String: Any]
  #expect(parsed["oauth_token"] as? String == "x//y/*z*/,}")
  #expect(parsed["array"] as? [Int] == [1, 2])
  #expect(throws: MeterError.self) { try CopilotProvider.jsonData(Data("{/* unfinished".utf8)) }
}

private actor CopilotTransport: HTTPTransport {
  var requests: [URLRequest] = []
  let changedSource: URL?
  init(changedSource: URL? = nil) { self.changedSource = changedSource }
  func data(for request: URLRequest) async throws -> Data {
    requests.append(request)
    #expect(request.url?.host == "api.github.com")
    #expect(request.httpMethod == "GET")
    #expect(request.httpBody == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "token fixture")
    if request.url?.path == "/user" { return Data(#"{"id":123,"login":"octocat"}"#.utf8) }
    #expect(request.url?.path == "/copilot_internal/user")
    if let changedSource { try Data(#"{"oauth_token":"changed"}"#.utf8).write(to: changedSource) }
    return Data(quota.utf8)
  }
}

@Test(arguments: ["single", "editor", "cli"])
func copilotReadsExistingCredentialsWithoutChangingSource(shape: String) async throws {
  let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: source) }
  let json: String =
    switch shape {
    case "editor": #"{"github.com:app":{"user":"octocat","oauth_token":"fixture"}}"#
    case "cli":
      #"{/* CLI config */ "lastLoggedInUser":{"host":"https://github.com","login":"octocat"},"copilotTokens":{"https://github.com:octocat":"fixture"},}"#
    default: #"{"host":"github.com","oauth_token":"fixture","user":"octocat"}"#
    }
  let data = Data(json.utf8)
  try data.write(to: source)
  let network = CopilotTransport()
  let snapshot = try await CopilotProvider(network: network).fetch(
    configuration: .init(provider: .copilot, sourcePath: source.path))
  #expect(snapshot.provider == .copilot)
  #expect(snapshot.accountID != "123")
  #expect(snapshot.accountLabel == "o••• · github.com")
  #expect(try Data(contentsOf: source) == data)
  #expect(await network.requests.count == 2)
}

@Test func copilotDiscardsChangedCredentialsAndRejectsForeignHosts() async throws {
  let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: source) }
  try Data(#"{"oauth_token":"fixture"}"#.utf8).write(to: source)
  let network = CopilotTransport(changedSource: source)
  await #expect(throws: MeterError.self) {
    try await CopilotProvider(network: network).fetch(
      configuration: .init(provider: .copilot, sourcePath: source.path))
  }
  try Data(#"{"host":"evil.example","oauth_token":"fixture"}"#.utf8).write(to: source)
  let rejected = CopilotTransport()
  await #expect(throws: MeterError.self) {
    try await CopilotProvider(network: rejected).fetch(
      configuration: .init(provider: .copilot, sourcePath: source.path))
  }
  #expect(await rejected.requests.isEmpty)
}

@Test func oldSettingsGainCopilotWithoutChangingExistingPreferences() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  var settings = AppSettings()
  settings.services = [
    .init(provider: .claude), .init(provider: .antigravity), .init(provider: .codex),
  ]
  settings.services[0].visible = false
  settings.showRemaining = true
  let original = try JSONEncoder().encode(settings)
  let file = directory.appendingPathComponent("settings.json")
  try original.write(to: file)
  let migrated = try LocalStorage(directory: directory).loadSettings()
  #expect(migrated.services.prefix(3).map(\.provider) == [.claude, .antigravity, .codex])
  #expect(migrated.services.last?.provider == .copilot)
  #expect(!migrated.services[0].visible)
  #expect(migrated.showRemaining)
  #expect(try Data(contentsOf: file) == original)
  try migrated.validate()
}
