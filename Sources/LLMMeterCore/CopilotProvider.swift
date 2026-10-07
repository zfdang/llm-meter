import Foundation
import LocalAuthentication
import Security

public struct CopilotProvider: UsageProvider {
  public let network: any HTTPTransport
  public init(network: any HTTPTransport = NetworkTransport()) { self.network = network }
  private struct Credential: Equatable {
    let token: String
    let login: String?
  }

  public func fetch(configuration: ServiceConfiguration) async throws -> UsageSnapshot {
    let candidates = try credentials(configuration.sourcePath)
    var rejected = MeterError.authentication(
      "Copilot rejected the existing sign-in. Sign in through Copilot, then refresh.")
    for before in candidates.prefix(8) {
      do {
        let identity = try await query("/user", token: before.token)
        guard let user = try? JSONSerialization.jsonObject(with: identity) as? [String: Any],
          let id = user["id"] as? NSNumber, let login = user["login"] as? String,
          before.login == nil || before.login?.lowercased() == login.lowercased()
        else {
          throw MeterError.authentication(
            "Cannot confirm the Copilot account. Sign in through Copilot, then refresh.")
        }
        let quota = try await query("/copilot_internal/user", token: before.token)
        guard try credentials(configuration.sourcePath) == candidates else {
          throw MeterError.connection("Copilot sign-in changed during refresh. Refresh again.")
        }
        return try CopilotParser.parse(
          quota, accountID: SourceFiles.identifier("github.com:\(id)"),
          accountLabel: login.first.map { "\($0)••• · github.com" } ?? "GitHub account", now: Date()
        )
      } catch MeterError.authentication(let message) {
        rejected = .authentication(message)
      }
    }
    throw rejected
  }

  private func query(_ path: String, token: String) async throws -> Data {
    var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
    request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("LLMMeter/0.1", forHTTPHeaderField: "User-Agent")
    return try await network.data(for: request)
  }

  private func credentials(_ custom: String) throws -> [Credential] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? "\(home)/.config"
    let cli = ProcessInfo.processInfo.environment["COPILOT_HOME"] ?? "\(home)/.copilot"
    let paths =
      custom.isEmpty
      ? [
        "\(config)/github-copilot/apps.json", "\(config)/github-copilot/hosts.json",
        "\(cli)/config.json",
      ] : [custom]
    for path in paths {
      if custom.isEmpty && !FileManager.default.fileExists(atPath: path) { continue }
      guard
        let root = try? JSONSerialization.jsonObject(with: Self.jsonData(SourceFiles.read(path)))
          as? [String: Any]
      else {
        if !custom.isEmpty { throw MeterError.malformed("Unrecognized Copilot sign-in JSON.") }
        continue
      }
      if let token = root["oauth_token"] as? String, !token.isEmpty {
        guard Self.githubHost(root["host"] as? String ?? "github.com") else {
          throw MeterError.unsupported(
            "This Copilot adapter currently supports github.com accounts.")
        }
        return [Credential(token: token, login: root["user"] as? String)]
      }
      let editor = root.keys.sorted().filter { $0 == "github.com" || $0.hasPrefix("github.com:") }
        .compactMap { key -> Credential? in
          guard let entry = root[key] as? [String: Any],
            let token = entry["oauth_token"] as? String, !token.isEmpty
          else { return nil }
          return Credential(token: token, login: entry["user"] as? String)
        }
      if !editor.isEmpty {
        let users = Set(editor.compactMap { $0.login?.lowercased() })
        guard users.count <= 1, editor.count == 1 || editor.allSatisfy({ $0.login != nil }) else {
          throw MeterError.connection(
            "Multiple Copilot accounts found. Choose a single-account OAuth JSON source in Settings."
          )
        }
        return editor
      }
      let users = root["loggedInUsers"] as? [[String: String]] ?? []
      let selected =
        root["lastLoggedInUser"] as? [String: String] ?? (users.count == 1 ? users[0] : nil)
      if let selected, let login = selected["login"], let host = selected["host"],
        Self.githubHost(host)
      {
        let account = "https://github.com:\(login)"
        let tokens = root["copilotTokens"] as? [String: String] ?? [:]
        let token = tokens[account] ?? Self.keychain(account)
        if let token, !token.isEmpty { return [Credential(token: token, login: login)] }
      }
    }
    throw MeterError.connection(
      "Sign in through a Copilot editor or Copilot CLI, then refresh. A single-account OAuth JSON source can also be selected in Settings. Keychain reads do not prompt for access."
    )
  }

  private static func githubHost(_ host: String) -> Bool {
    ["github.com", "https://github.com", "https://github.com/"].contains(host.lowercased())
  }
  private static func keychain(_ account: String) -> String? {
    let context = LAContext()
    context.interactionNotAllowed = true
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "copilot-cli", kSecAttrAccount as String: account,
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
      kSecUseAuthenticationContext as String: context,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Removes JSONC comments and trailing commas without changing quoted tokens.
  static func jsonData(_ data: Data) throws -> Data {
    let input = Array(String(decoding: data, as: UTF8.self))
    var output: [Character] = []
    var index = 0
    var quoted = false
    var escaped = false
    while index < input.count {
      let char = input[index]
      if quoted {
        output.append(char)
        if escaped {
          escaped = false
        } else if char == "\\" {
          escaped = true
        } else if char == "\"" {
          quoted = false
        }
        index += 1
        continue
      }
      if char == "\"" { quoted = true }
      if char == "/", index + 1 < input.count, input[index + 1] == "/" {
        while index < input.count && input[index] != "\n" { index += 1 }
        output.append(" ")
        continue
      }
      if char == "/", index + 1 < input.count, input[index + 1] == "*" {
        index += 2
        while index + 1 < input.count && !(input[index] == "*" && input[index + 1] == "/") {
          index += 1
        }
        guard index + 1 < input.count else {
          throw MeterError.malformed("Invalid Copilot JSON comment.")
        }
        index += 2
        output.append(" ")
        continue
      }
      output.append(char)
      index += 1
    }
    var clean: [Character] = []
    quoted = false
    escaped = false
    for index in output.indices {
      let char = output[index]
      if !quoted && char == "," {
        var next = index + 1
        while next < output.count && output[next].isWhitespace { next += 1 }
        if next < output.count && (output[next] == "}" || output[next] == "]") { continue }
      }
      clean.append(char)
      if quoted && escaped {
        escaped = false
      } else if quoted && char == "\\" {
        escaped = true
      } else if char == "\"" {
        quoted.toggle()
      }
    }
    return Data(String(clean).utf8)
  }
}
