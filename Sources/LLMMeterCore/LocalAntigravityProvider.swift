import Darwin
import Foundation

/// Reads the installed client's loopback status RPCs without managing its login.
struct LocalAntigravityProvider: UsageProvider {
  let network: any HTTPTransport
  let commands: any CommandRunning
  struct Server: Equatable, Sendable {
    let pid: Int
    let csrf: String
    let standalone: Bool
  }

  static func servers(_ output: String) -> [Server] {
    output.split(separator: "\n").compactMap { line in
      let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
      guard parts.count == 2, let pid = Int(parts[0]), pid > 0 else { return nil }
      let command = String(parts[1])
      guard
        command.range(
          of: #"^/[^\s]*?/Antigravity\.app/Contents/[^\s]*?/language_server(?:_macos_arm)?\s"#,
          options: .regularExpression) != nil,
        let range = command.range(
          of: #"--csrf_token(?:=|\s+)[A-Za-z0-9-]+"#, options: .regularExpression)
      else { return nil }
      let flag = String(command[range])
      let csrf = flag.replacingOccurrences(
        of: #"^--csrf_token(?:=|\s+)"#, with: "", options: .regularExpression)
      return Server(pid: pid, csrf: csrf, standalone: command.contains("--standalone"))
    }.sorted {
      if $0.standalone != $1.standalone { return $0.standalone }
      return $0.pid < $1.pid
    }
  }

  static func ports(_ output: String) -> [Int] {
    Set(
      output.split(separator: "\n").compactMap { line -> Int? in
        // lsof -nP -Fn provides numeric addresses. Reject non-loopback listeners.
        guard line.hasPrefix("n127.0.0.1:") || line.hasPrefix("n[::1]:"),
          let text = line.split(separator: ":").last, let port = Int(text),
          (1...65535).contains(port)
        else { return nil }
        return port
      }
    ).sorted(by: >)
  }

  private func discover() async throws -> [Server] {
    let result = try await commands.run(
      executable: "/bin/ps",
      arguments: ["-U", String(getuid()), "-o", "pid=,command="], timeout: 5)
    guard result.status == 0 else { return [] }
    return Self.servers(String(decoding: result.output, as: UTF8.self))
  }

  func fetch(configuration: ServiceConfiguration) async throws -> UsageSnapshot {
    let servers = try await discover()
    guard !servers.isEmpty else {
      throw MeterError.connection(
        "Open Antigravity and sign in, then refresh. Automatic monitoring reads its running local language server."
      )
    }
    for server in servers.prefix(4) {
      let listeners = try await commands.run(
        executable: "/usr/sbin/lsof",
        arguments: ["-nP", "-a", "-p", String(server.pid), "-iTCP", "-sTCP:LISTEN", "-Fn"],
        timeout: 5)
      for port in Self.ports(String(decoding: listeners.output, as: UTF8.self)).prefix(4) {
        let status: Data
        do {
          status = try await query("GetUserStatus", server: server, port: port)
        } catch MeterError.cancelled { throw MeterError.cancelled } catch MeterError.rateLimited(
          let delay)
        { throw MeterError.rateLimited(delay) } catch { continue }
        var snapshot = try AntigravityParsers.status(status, now: Date())
        do {
          let data = try await query("RetrieveUserQuotaSummary", server: server, port: port)
          let metrics = try AntigravityParsers.summary(data, now: snapshot.readAt)
          if !metrics.isEmpty {
            snapshot.metrics += metrics
            snapshot.complete = true
          }
        } catch MeterError.cancelled { throw MeterError.cancelled } catch MeterError.rateLimited(
          let delay)
        { throw MeterError.rateLimited(delay) } catch {
          // Older clients can still expose model quotas through GetUserStatus.
        }
        guard try await discover().contains(server) else {
          throw MeterError.connection("Antigravity restarted during refresh. Refresh again.")
        }
        let after = try AntigravityParsers.status(
          await query("GetUserStatus", server: server, port: port), now: snapshot.readAt)
        guard after.accountID == snapshot.accountID else {
          throw MeterError.connection("Antigravity account changed during refresh. Refresh again.")
        }
        guard !snapshot.metrics.isEmpty else {
          throw MeterError.unsupported(
            "Antigravity did not report any quota values for this account.")
        }
        return snapshot
      }
    }
    throw MeterError.connection(
      "Cannot read Antigravity's local status interface. Keep Antigravity running and signed in, then refresh."
    )
  }

  private func query(_ method: String, server: Server, port: Int) async throws -> Data {
    var request = URLRequest(
      url: URL(
        string:
          "http://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/\(method)")!)
    request.timeoutInterval = 5
    request.httpMethod = "POST"
    request.httpBody = Data("{}".utf8)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    request.setValue(server.csrf, forHTTPHeaderField: "X-Codeium-Csrf-Token")
    return try await network.data(for: request)
  }
}
