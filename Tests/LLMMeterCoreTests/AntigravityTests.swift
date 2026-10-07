import Foundation
import Testing

@testable import LLMMeterCore

private let status =
  #"{"userStatus":{"email":"a@example.com","planStatus":{"planInfo":{"planName":"Pro"}},"cascadeModelConfigData":{"clientModelConfigs":[{"modelId":"gemini","label":"Gemini","quotaInfo":{"remainingFraction":0.6}},{"modelId":"claude","label":"Claude","quotaInfo":{}}]}}}"#
private let summary =
  #"{"response":{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"g5","window":"5h","remainingFraction":0.7},{"bucketId":"gw","window":"weekly"}]},{"displayName":"Claude and GPT","buckets":[{"window":"5h","remainingFraction":0},{"window":"weekly","remainingFraction":0.9},{"window":"daily","remainingFraction":0.5,"disabled":true}]}]}}"#

@Test func antigravitySummaryKeepsPoolsAndUnknownValuesSeparate() throws {
  let metrics = try AntigravityParsers.summary(Data(summary.utf8), now: .now)
  #expect(metrics.count == 4)
  #expect(metrics[0].period == .fiveHours)
  #expect(metrics[1].period == .weekly)
  #expect(metrics[1].usedPercent == nil)
  #expect(metrics[2].usedPercent == 100)
  #expect(metrics[0].scope != metrics[2].scope)
  #expect(metrics.allSatisfy { $0.resetAt == nil })
  #expect(throws: MeterError.self) {
    try AntigravityParsers.summary(
      Data(summary.replacingOccurrences(of: "0.7", with: "1.1").utf8), now: .now)
  }
  let snapshot = try AntigravityParsers.status(Data(status.utf8), now: .now)
  #expect(snapshot.plan == "Pro")
  #expect(snapshot.metrics[1].usedPercent == nil)
  #expect(snapshot.metrics.allSatisfy { $0.period == .other })
  #expect(snapshot.accountID != "a@example.com")
}

@Test func antigravityDiscoveryRejectsUnrelatedProcessesAndPublicListeners() {
  let output = """
    10 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --csrf_token=test-token
    20 /Applications/Other.app/Contents/bin/language_server --csrf_token secret
    30 /usr/bin/python /Applications/Antigravity.app/Contents/bin/language_server --csrf_token stolen
    """
  let servers = LocalAntigravityProvider.servers(output)
  #expect(servers.count == 1)
  #expect(servers.first?.pid == 10)
  #expect(servers.first?.csrf == "test-token")
  #expect(
    LocalAntigravityProvider.ports(
      "n*:1234\nn192.168.1.2:5678\nn127.0.0.1:5000\nn[::1]:5001\nn127.0.0.1:5000") == [5001, 5000])
}

private actor LocalCommands: CommandRunning {
  var discoveries = 0
  let restart: Bool
  init(restart: Bool = false) { self.restart = restart }
  func run(executable: String, arguments: [String], timeout: TimeInterval) async throws
    -> CommandResult
  {
    if executable == "/bin/ps" {
      discoveries += 1
      let token = restart && discoveries > 1 ? "new-token" : "test-token"
      return .init(
        output: Data(
          "10 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --csrf_token \(token)"
            .utf8), status: 0)
    }
    #expect(executable == "/usr/sbin/lsof")
    #expect(arguments.contains("10"))
    return .init(output: Data("p10\nf7\nn127.0.0.1:5000".utf8), status: 0)
  }
}
private actor LocalTransport: HTTPTransport {
  var reads = 0
  var methods: [String] = []
  let switchAccount: Bool
  let summaryAvailable: Bool
  init(switchAccount: Bool = false, summaryAvailable: Bool = true) {
    self.switchAccount = switchAccount
    self.summaryAvailable = summaryAvailable
  }
  func data(for request: URLRequest) async throws -> Data {
    #expect(request.url?.host == "127.0.0.1")
    #expect(request.url?.port == 5000)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.value(forHTTPHeaderField: "X-Codeium-Csrf-Token") == "test-token")
    #expect(request.httpBody == Data("{}".utf8))
    let method = request.url!.lastPathComponent
    methods.append(method)
    if method == "RetrieveUserQuotaSummary" {
      if !summaryAvailable { throw MeterError.unsupported("Older client") }
      return Data(summary.utf8)
    }
    #expect(method == "GetUserStatus")
    reads += 1
    let value =
      switchAccount && reads > 1
      ? status.replacingOccurrences(of: "a@example.com", with: "b@example.com") : status
    return Data(value.utf8)
  }
}

@Test(arguments: [false, true], [false, true])
func localAntigravityRejectsAccountChangesAndRestarts(switchAccount: Bool, restart: Bool)
  async throws
{
  let network = LocalTransport(switchAccount: switchAccount)
  let provider = AntigravityProvider(network: network, commands: LocalCommands(restart: restart))
  if switchAccount || restart {
    await #expect(throws: MeterError.self) {
      try await provider.fetch(configuration: .init(provider: .antigravity))
    }
  } else {
    let snapshot = try await provider.fetch(configuration: .init(provider: .antigravity))
    #expect(snapshot.complete)
    #expect(snapshot.metrics.count == 6)
    #expect(snapshot.accountLabel == "a•••@example.com")
    #expect(
      await network.methods == ["GetUserStatus", "RetrieveUserQuotaSummary", "GetUserStatus"])
  }
}

@Test func localAntigravityFallsBackToModelsWithoutInventingWeeklyUsage() async throws {
  let provider = AntigravityProvider(
    network: LocalTransport(summaryAvailable: false), commands: LocalCommands())
  let snapshot = try await provider.fetch(configuration: .init(provider: .antigravity))
  #expect(!snapshot.complete)
  #expect(snapshot.metrics.count == 2)
  #expect(snapshot.metrics.allSatisfy { $0.period == .other })
}
