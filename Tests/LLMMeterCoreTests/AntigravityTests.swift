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
  let daemonDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString)
  try FileManager.default.createDirectory(at: daemonDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: daemonDirectory) }
  let network = LocalTransport(switchAccount: switchAccount)
  let provider = AntigravityProvider(
    network: network, commands: LocalCommands(restart: restart), daemonDirectory: daemonDirectory)
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
  let daemonDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString)
  try FileManager.default.createDirectory(at: daemonDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: daemonDirectory) }
  let provider = AntigravityProvider(
    network: LocalTransport(summaryAvailable: false), commands: LocalCommands(),
    daemonDirectory: daemonDirectory)
  let snapshot = try await provider.fetch(configuration: .init(provider: .antigravity))
  #expect(!snapshot.complete)
  #expect(snapshot.metrics.count == 2)
  #expect(snapshot.metrics.allSatisfy { $0.period == .other })
}

@Test func antigravityDiscoveryMatchesDaemonMetadataAndRejectsStaleOrForeignPIDs() {
  let output = """
    10 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --read_host_bridge_token_from_stdin
    20 /Applications/Other.app/Contents/bin/language_server --read_host_bridge_token_from_stdin
    30 /usr/bin/python /Applications/Antigravity.app/Contents/bin/language_server --read_host_bridge_token_from_stdin
    40 /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token legacy-token
    """
  let daemons = [
    LocalAntigravityProvider.DaemonMetadata(
      pid: 99, csrf: "stale-token", httpPort: 50735, preferred: true),
    LocalAntigravityProvider.DaemonMetadata(
      pid: 20, csrf: "other-app-token", httpPort: 50736, preferred: true),
    LocalAntigravityProvider.DaemonMetadata(
      pid: 30, csrf: "wrapped-token", httpPort: 50737, preferred: true),
    LocalAntigravityProvider.DaemonMetadata(
      pid: 10, csrf: "daemon-token", httpPort: 50735, preferred: true),
  ]
  let servers = LocalAntigravityProvider.servers(output, daemons: daemons)
  #expect(
    servers == [
      .init(pid: 10, csrf: "daemon-token", httpPort: 50735, standalone: true),
      .init(pid: 40, csrf: "legacy-token", httpPort: nil, standalone: false),
    ])
  #expect(
    LocalAntigravityProvider.candidatePorts(
      listening: [65035, 50757, 50754, 50735, 50734, 49000], preferred: 50735)
      == [50735, 65035, 50757, 50754, 50734, 49000])
  #expect(
    LocalAntigravityProvider.candidatePorts(
      listening: [65035, 50757, 50754, 50734], preferred: 50735)
      == [65035, 50757, 50754, 50734])
}

private actor DaemonLocalCommands: CommandRunning {
  var discoveries = 0
  let rotateTokenFile: URL?
  init(rotateTokenFile: URL? = nil) { self.rotateTokenFile = rotateTokenFile }
  func run(executable: String, arguments: [String], timeout: TimeInterval) async throws
    -> CommandResult
  {
    if executable == "/bin/ps" {
      discoveries += 1
      if let rotateTokenFile, discoveries > 1 {
        let rotated = """
          {"pid":1994,"httpsPort":50734,"httpPort":50735,"lsVersion":"2.34.0","csrfToken":"rotated-token"}
          """
        try Data(rotated.utf8).write(to: rotateTokenFile)
      }
      return .init(
        output: Data(
          "1994 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --read_host_bridge_token_from_stdin"
            .utf8), status: 0)
    }
    #expect(executable == "/usr/sbin/lsof")
    #expect(arguments.contains("1994"))
    return .init(
      output: Data(
        "p1994\nf7\nn127.0.0.1:50734\nf8\nn127.0.0.1:50735\nf9\nn127.0.0.1:50754\nf10\nn127.0.0.1:50757\nf11\nn127.0.0.1:65035\nf12\nn127.0.0.1:65036"
          .utf8), status: 0)
  }
}

private actor DaemonLocalTransport: HTTPTransport {
  var ports: [Int] = []
  func data(for request: URLRequest) async throws -> Data {
    #expect(request.url?.host == "127.0.0.1")
    #expect(request.value(forHTTPHeaderField: "X-Codeium-Csrf-Token") == "daemon-test-token")
    let port = request.url?.port ?? 0
    ports.append(port)
    #expect(port == 50735)
    let method = request.url!.lastPathComponent
    if method == "RetrieveUserQuotaSummary" { return Data(summary.utf8) }
    #expect(method == "GetUserStatus")
    return Data(status.utf8)
  }
}

@Test func localAntigravityReadsDaemonDiscoveryFilesAndPrioritizesVerifiedHTTPPort() async throws {
  let daemonDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString)
  try FileManager.default.createDirectory(at: daemonDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: daemonDirectory) }

  let hubFile = daemonDirectory.appendingPathComponent("hub_50735.json")
  let valid = """
    {"pid":1994,"httpsPort":50734,"httpPort":50735,"lsVersion":"2.34.0","csrfToken":"daemon-test-token"}
    """
  try Data(valid.utf8).write(to: hubFile)

  let staleFile = daemonDirectory.appendingPathComponent("hub_99999.json")
  let stale = """
    {"pid":99999,"httpsPort":59998,"httpPort":59999,"lsVersion":"2.34.0","csrfToken":"stale-token"}
    """
  try Data(stale.utf8).write(to: staleFile)

  let corruptFile = daemonDirectory.appendingPathComponent("corrupt.json")
  try Data("{invalid json".utf8).write(to: corruptFile)

  let targetFile = FileManager.default.temporaryDirectory.appendingPathComponent(
    "symlink-target-\(UUID().uuidString).json")
  try Data(
    """
    {"pid":1994,"httpPort":65036,"csrfToken":"symlink-token"}
    """.utf8
  ).write(to: targetFile)
  defer { try? FileManager.default.removeItem(at: targetFile) }
  let symlinkFile = daemonDirectory.appendingPathComponent("hub_65036.json")
  try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: targetFile)

  let metadata = LocalAntigravityProvider.daemonMetadata(in: daemonDirectory)
  #expect(metadata.count == 2)
  #expect(!metadata.contains(where: { $0.csrf == "symlink-token" }))

  let transport = DaemonLocalTransport()
  let provider = AntigravityProvider(
    network: transport, commands: DaemonLocalCommands(), daemonDirectory: daemonDirectory)
  let snapshot = try await provider.fetch(configuration: .init(provider: .antigravity))
  #expect(snapshot.complete)
  #expect(snapshot.metrics.count == 6)
  #expect(snapshot.accountLabel == "a•••@example.com")
  #expect(await transport.ports == [50735, 50735, 50735])

  let restartingProvider = AntigravityProvider(
    network: DaemonLocalTransport(),
    commands: DaemonLocalCommands(rotateTokenFile: hubFile),
    daemonDirectory: daemonDirectory)
  await #expect(throws: MeterError.self) {
    try await restartingProvider.fetch(configuration: .init(provider: .antigravity))
  }
}
