import Darwin
import Foundation

/// Reads the installed client's loopback status RPCs without managing its login.
struct LocalAntigravityProvider: UsageProvider {
  static var defaultDaemonDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      ".gemini/antigravity/daemon", isDirectory: true)
  }

  let network: any HTTPTransport
  let commands: any CommandRunning
  let daemonDirectory: URL

  init(
    network: any HTTPTransport, commands: any CommandRunning,
    daemonDirectory: URL = Self.defaultDaemonDirectory
  ) {
    self.network = network
    self.commands = commands
    self.daemonDirectory = daemonDirectory
  }

  struct DaemonMetadata: Equatable, Sendable {
    let pid: Int
    let csrf: String
    let httpPort: Int?
    let preferred: Bool
  }

  struct Server: Equatable, Sendable {
    let pid: Int
    let csrf: String
    let httpPort: Int?
    let standalone: Bool

    init(pid: Int, csrf: String, httpPort: Int? = nil, standalone: Bool) {
      self.pid = pid
      self.csrf = csrf
      self.httpPort = httpPort
      self.standalone = standalone
    }
  }

  static func daemonMetadata(in directory: URL) -> [DaemonMetadata] {
    let manager = FileManager.default
    guard
      let urls = try? manager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
    else { return [] }
    struct DaemonFile: Decodable {
      let pid: Int?
      let httpPort: Int?
      let csrfToken: String?

      private enum CodingKeys: String, CodingKey {
        case pid, httpPort, csrfToken
        case snakeHTTPPort = "http_port"
        case snakeCSRFToken = "csrf_token"
      }

      init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pid = try values.decodeIfPresent(Int.self, forKey: .pid)
        httpPort =
          try values.decodeIfPresent(Int.self, forKey: .httpPort)
          ?? values.decodeIfPresent(Int.self, forKey: .snakeHTTPPort)
        csrfToken =
          try values.decodeIfPresent(String.self, forKey: .csrfToken)
          ?? values.decodeIfPresent(String.self, forKey: .snakeCSRFToken)
      }
    }
    let currentUID = getuid()
    let decoder = JSONDecoder()
    return
      urls
      .filter { $0.pathExtension.lowercased() == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { url -> DaemonMetadata? in
        guard
          let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
          ]),
          values.isSymbolicLink != true,
          values.isRegularFile == true,
          let size = values.fileSize, size > 0, size <= 65_536,
          let attributes = try? manager.attributesOfItem(atPath: url.path),
          (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == currentUID,
          let data = try? Data(contentsOf: url),
          let file = try? decoder.decode(DaemonFile.self, from: data),
          let pid = file.pid, pid > 0,
          let csrf = file.csrfToken,
          isValidCSRF(csrf)
        else { return nil }
        let httpPort = file.httpPort.flatMap { (1...65535).contains($0) ? $0 : nil }
        return DaemonMetadata(
          pid: pid, csrf: csrf, httpPort: httpPort,
          preferred: url.lastPathComponent.hasPrefix("hub_"))
      }
  }

  private static func isValidCSRF(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 512 else { return false }
    return value.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7E }
  }

  static func servers(_ output: String, daemons: [DaemonMetadata] = []) -> [Server] {
    var result: [Server] = []
    for line in output.split(separator: "\n") {
      let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
      guard parts.count == 2, let pid = Int(parts[0]), pid > 0 else { continue }
      let command = String(parts[1])
      guard
        command.range(
          of:
            #"^/[^\s]*?/Antigravity\.app/Contents/[^\s]*?/language_server(?:_macos_arm)?(?:\s|$)"#,
          options: .regularExpression) != nil
      else { continue }
      let standalone = command.contains("--standalone")
      let cliCSRF: String? =
        command.range(of: #"--csrf_token(?:=|\s+)[A-Za-z0-9_-]+"#, options: .regularExpression).map
      {
        String(command[$0]).replacingOccurrences(
          of: #"^--csrf_token(?:=|\s+)"#, with: "", options: .regularExpression)
      }
      let matchedDaemons = daemons.filter { $0.pid == pid }.sorted {
        if $0.preferred != $1.preferred { return $0.preferred }
        if ($0.httpPort != nil) != ($1.httpPort != nil) { return $0.httpPort != nil }
        if ($0.httpPort ?? 0) != ($1.httpPort ?? 0) {
          return ($0.httpPort ?? 0) < ($1.httpPort ?? 0)
        }
        return $0.csrf < $1.csrf
      }
      for daemon in matchedDaemons {
        let candidate = Server(
          pid: pid, csrf: daemon.csrf, httpPort: daemon.httpPort, standalone: standalone)
        if !result.contains(candidate) { result.append(candidate) }
      }
      if let cliCSRF, !matchedDaemons.contains(where: { $0.csrf == cliCSRF }) {
        let candidate = Server(pid: pid, csrf: cliCSRF, httpPort: nil, standalone: standalone)
        if !result.contains(candidate) { result.append(candidate) }
      }
    }
    return result.sorted {
      if $0.standalone != $1.standalone { return $0.standalone }
      if ($0.httpPort != nil) != ($1.httpPort != nil) { return $0.httpPort != nil }
      if $0.pid != $1.pid { return $0.pid < $1.pid }
      if ($0.httpPort ?? 0) != ($1.httpPort ?? 0) {
        return ($0.httpPort ?? 0) < ($1.httpPort ?? 0)
      }
      return $0.csrf < $1.csrf
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

  static func candidatePorts(listening: [Int], preferred: Int?) -> [Int] {
    if let preferred, listening.contains(preferred) {
      return Array(([preferred] + listening.filter { $0 != preferred }).prefix(8))
    }
    return Array(listening.prefix(8))
  }

  private func discover() async throws -> [Server] {
    let result = try await commands.run(
      executable: "/bin/ps",
      arguments: ["-U", String(getuid()), "-o", "pid=,command="], timeout: 5)
    guard result.status == 0 else { return [] }
    let daemons = Self.daemonMetadata(in: daemonDirectory)
    return Self.servers(String(decoding: result.output, as: UTF8.self), daemons: daemons)
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
      guard listeners.status == 0 else { continue }
      let listeningPorts = Self.ports(String(decoding: listeners.output, as: UTF8.self))
      for port in Self.candidatePorts(listening: listeningPorts, preferred: server.httpPort) {
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
