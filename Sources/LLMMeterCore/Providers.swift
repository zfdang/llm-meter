import CryptoKit
import Foundation

public protocol UsageProvider: Sendable {
  func fetch(configuration: ServiceConfiguration) async throws -> UsageSnapshot
}

public struct ProviderRegistry: UsageProvider {
  public let network: any HTTPTransport
  public let commands: any CommandRunning
  public init(
    network: any HTTPTransport = NetworkTransport(), commands: any CommandRunning = ProcessRunner()
  ) {
    self.network = network
    self.commands = commands
  }
  public func fetch(configuration: ServiceConfiguration) async throws -> UsageSnapshot {
    switch configuration.provider {
    case .codex: try await CodexProvider(network: network).fetch(configuration: configuration)
    case .claude: try await ClaudeProvider(commands: commands).fetch(configuration: configuration)
    case .antigravity:
      try await AntigravityProvider(network: network).fetch(configuration: configuration)
    }
  }
}

public enum SourceFiles {
  public static func read(_ path: String) throws -> Data {
    let path = NSString(string: path).expandingTildeInPath
    do {
      let url = URL(fileURLWithPath: path)
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= 1_000_000 else {
        throw MeterError.malformed("The credential file is too large.")
      }
      return try Data(contentsOf: url)
    } catch let error as MeterError { throw error } catch {
      throw MeterError.connection(
        "Cannot read the sign-in source. Choose a file in Settings or sign in through the original tool."
      )
    }
  }
  public static func identifier(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  public static func masked(_ email: String?) -> String {
    guard let email, let at = email.firstIndex(of: "@"), let first = email.first else {
      return "Current account"
    }
    return "\(first)•••\(email[at...])"
  }
  public static func jwt(_ token: String) -> [String: Any] {
    let parts = token.split(separator: ".")
    guard parts.count == 3 else { return [:] }
    var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object
  }
}

public struct CodexProvider: UsageProvider {
  public let network: any HTTPTransport
  public init(network: any HTTPTransport = NetworkTransport()) { self.network = network }
  private struct Auth: Decodable {
    struct Tokens: Decodable {
      let accessToken: String
      let accountId: String?
      let idToken: String?
    }
    let authMode: String?
    let tokens: Tokens?
  }
  private func credentials(_ path: String) throws -> Auth.Tokens {
    let auth: Auth
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    do { auth = try decoder.decode(Auth.self, from: SourceFiles.read(path)) } catch let error
      as MeterError
    { throw error } catch { throw MeterError.malformed("Unrecognized Codex sign-in file.") }
    guard auth.authMode != "apikey", let tokens = auth.tokens, !tokens.accessToken.isEmpty,
      let account = tokens.accountId, !account.isEmpty
    else {
      throw MeterError.authentication(
        "A Codex subscription sign-in is required; API key authentication has no subscription quota."
      )
    }
    if let expires = SourceFiles.jwt(tokens.accessToken)["exp"] as? Double,
      expires <= Date().timeIntervalSince1970
    {
      throw MeterError.authentication(
        "Codex sign-in expired. Open Codex to renew it, then refresh.")
    }
    return tokens
  }
  public func fetch(configuration: ServiceConfiguration) async throws -> UsageSnapshot {
    let defaultDirectory =
      ProcessInfo.processInfo.environment["CODEX_HOME"]
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
    let path =
      configuration.sourcePath.isEmpty ? defaultDirectory + "/auth.json" : configuration.sourcePath
    let tokens = try credentials(path)
    var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
    request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue(tokens.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let data = try await network.data(for: request)
    let current = try credentials(path)
    guard current.accountId == tokens.accountId else {
      throw MeterError.connection("Codex account changed during refresh. Refresh again.")
    }
    let claims = SourceFiles.jwt(tokens.idToken ?? "")
    let identity = "\(tokens.accountId ?? ""):\(claims["sub"] as? String ?? "")"
    let currentClaims = SourceFiles.jwt(current.idToken ?? "")
    guard currentClaims["sub"] as? String == claims["sub"] as? String else {
      throw MeterError.connection("Codex account changed during refresh. Refresh again.")
    }
    return try UsageParsers.codex(
      data, accountID: SourceFiles.identifier(identity),
      accountLabel: SourceFiles.masked(claims["email"] as? String), now: Date())
  }
}

public struct ClaudeProvider: UsageProvider {
  public let commands: any CommandRunning
  public init(commands: any CommandRunning = ProcessRunner()) { self.commands = commands }
  private struct Identity: Decodable, Equatable {
    let loggedIn: Bool
    let email: String?
    let authMethod: String?
    let orgId: String?
  }
  private func identity(_ executable: String) async throws -> Identity {
    let result = try await commands.run(
      executable: executable, arguments: ["auth", "status", "--json"], timeout: 10)
    guard let identity = try? JSONDecoder().decode(Identity.self, from: result.output),
      result.status == 0, identity.loggedIn, identity.email != nil,
      identity.authMethod != "api_key"
    else {
      throw MeterError.authentication(
        "Sign in to a Claude Code subscription in Terminal, then refresh.")
    }
    return identity
  }
  public func fetch(configuration: ServiceConfiguration) async throws -> UsageSnapshot {
    let executable = try ProcessRunner.executable("claude", configured: configuration.sourcePath)
    let version = try await commands.run(
      executable: executable, arguments: ["--version"], timeout: 10)
    let versionString = String(decoding: version.output, as: UTF8.self)
    guard Self.supportsUsage(versionString) else {
      throw MeterError.unsupported(
        "Claude Code 2.1.285 or newer is required for read-only print-mode usage.")
    }
    let before = try await identity(executable)
    let result = try await commands.run(
      executable: executable,
      arguments: [
        "-p", "/usage", "--output-format", "text", "--no-session-persistence",
        "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
        "--settings", "{\"disableAllHooks\":true}",
      ], timeout: 30)
    guard result.status == 0 else {
      throw MeterError.connection(
        "Claude Code could not read usage. Check its sign-in in Terminal.")
    }
    let after = try await identity(executable)
    guard before == after else {
      throw MeterError.connection("Claude Code account changed during refresh. Refresh again.")
    }
    let key = "\(before.email ?? ""):\(before.orgId ?? ""):\(before.authMethod ?? "")"
    return try UsageParsers.claude(
      String(decoding: result.output, as: UTF8.self),
      accountID: SourceFiles.identifier(key), accountLabel: SourceFiles.masked(before.email),
      now: Date())
  }
  public static func supportsUsage(_ version: String) -> Bool {
    guard let range = version.range(of: "[0-9]+\\.[0-9]+\\.[0-9]+", options: .regularExpression)
    else { return false }
    let parts = version[range].split(separator: ".").compactMap { Int($0) }
    guard parts.count == 3 else { return false }
    return !parts.lexicographicallyPrecedes([2, 1, 285])
  }
}

public struct AntigravityProvider: UsageProvider {
  public let network: any HTTPTransport
  public init(network: any HTTPTransport = NetworkTransport()) { self.network = network }
  private struct Credential: Decodable {
    struct Token: Decodable {
      let accessToken: String?
      let projectId: String?
    }
    let type: String?
    let accessToken: String?
    let projectId: String?
    let project: String?
    let token: Token?
    var access: String { accessToken ?? token?.accessToken ?? "" }
    var projectID: String { projectId ?? project ?? token?.projectId ?? "" }
  }
  private func credentials(_ path: String) throws -> Credential {
    let auth: Credential
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    do { auth = try decoder.decode(Credential.self, from: SourceFiles.read(path)) } catch let
      error as MeterError
    { throw error } catch {
      throw MeterError.malformed(
        "Choose a single-account Antigravity OAuth JSON file containing access_token and project_id."
      )
    }
    guard auth.type == nil || auth.type == "antigravity", !auth.access.isEmpty else {
      throw MeterError.authentication(
        "An Antigravity access token is required. Refresh-only exports are unsupported.")
    }
    return auth
  }
  public func fetch(configuration: ServiceConfiguration) async throws -> UsageSnapshot {
    guard !configuration.sourcePath.isEmpty else {
      throw MeterError.connection(
        "Choose an Antigravity OAuth JSON source in Settings. It must contain a current access_token; no tokens are copied or renewed."
      )
    }
    let auth = try credentials(configuration.sourcePath)
    struct User: Decodable {
      let id: String
      let email: String?
    }
    let userData = try await query(
      "https://www.googleapis.com/oauth2/v2/userinfo", access: auth.access)
    guard let user = try? JSONDecoder().decode(User.self, from: userData) else {
      throw MeterError.malformed("Cannot establish Antigravity account identity.")
    }
    var project = auth.projectID
    if project.isEmpty {
      let data = try await query(
        "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist", access: auth.access,
        body: [
          "metadata": [
            "ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED",
            "pluginType": "GEMINI",
          ]
        ])
      if let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        project =
          reply["cloudaicompanionProject"] as? String
          ?? (reply["cloudaicompanionProject"] as? [String: Any])?["id"] as? String ?? ""
      }
    }
    guard !project.isEmpty else {
      throw MeterError.connection(
        "Antigravity did not expose a project. Choose a source with project_id.")
    }
    let data = try await query(
      "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
      access: auth.access, body: ["project": project])
    let current = try credentials(configuration.sourcePath)
    guard current.access == auth.access, current.projectID == auth.projectID else {
      throw MeterError.connection("Antigravity source changed during refresh. Refresh again.")
    }
    return try UsageParsers.antigravity(
      data, accountID: SourceFiles.identifier(user.id),
      accountLabel: SourceFiles.masked(user.email), now: Date())
  }
  private func query(_ url: String, access: String, body: [String: Any]? = nil) async throws -> Data
  {
    var request = URLRequest(url: URL(string: url)!)
    request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
    request.setValue("LLMMeter/0.1 macOS/arm64", forHTTPHeaderField: "User-Agent")
    if let body {
      request.httpMethod = "POST"
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return try await network.data(for: request)
  }
}
