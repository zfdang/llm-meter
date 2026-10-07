import Darwin
import Foundation

public protocol HTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> Data
}

public struct NetworkTransport: HTTPTransport {
  public init() {}
  public func data(for request: URLRequest) async throws -> Data {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 25
    configuration.httpShouldSetCookies = false
    // Never forward credentials through redirects to another endpoint.
    let session = URLSession(
      configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    do {
      let (data, response) = try await session.data(for: request)
      guard let response = response as? HTTPURLResponse else { throw MeterError.network }
      switch response.statusCode {
      case 200..<300:
        guard data.count <= 2_000_000 else {
          throw MeterError.malformed("Usage response is too large.")
        }
        return data
      case 401, 403:
        throw MeterError.authentication("Sign in again through the original tool, then refresh.")
      case 429:
        let value = response.value(forHTTPHeaderField: "Retry-After") ?? ""
        let seconds =
          Double(value) ?? Self.retryDate(value).map { max(0, $0.timeIntervalSinceNow) } ?? 60
        throw MeterError.rateLimited(max(15, seconds))
      case 404: throw MeterError.unsupported("The usage endpoint is unavailable for this source.")
      default: throw MeterError.network
      }
    } catch let error as MeterError { throw error } catch let error as URLError
      where error.code == .timedOut
    { throw MeterError.timeout } catch is CancellationError { throw MeterError.cancelled } catch let
      error as URLError where error.code == .cancelled
    { throw MeterError.cancelled } catch { throw MeterError.network }
  }
  private static func retryDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: value)
  }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) { completionHandler(nil) }
}

public struct CommandResult: Sendable {
  public let output: Data
  public let status: Int32
  public init(output: Data, status: Int32) {
    self.output = output
    self.status = status
  }
}

public protocol CommandRunning: Sendable {
  func run(executable: String, arguments: [String], timeout: TimeInterval) async throws
    -> CommandResult
}

/// Owns and reaps one child. Launch, cancellation, and waitpid share the lock so a
/// child PID cannot be reaped/reused while shutdown is still signaling its group.
private final class ProcessControl: @unchecked Sendable {
  static let terminationSignals = DispatchGroup()
  /// Stop polling for a child that survived group SIGKILL, e.g. stuck in D-state.
  private static let reapTimeLimit: TimeInterval = 30
  private let lock = NSLock()
  private var pid: pid_t?
  private var status: Int32?
  private var cancelled = false
  private var stopping = false
  private var escalated = false
  private var reapDeadline: Date?
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func launch(
    executable: String, arguments: [String], environment: [String: String],
    directory: String, output: Int32, errors: Int32
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    if cancelled { throw MeterError.cancelled }
    var attributes: posix_spawnattr_t?
    var actions: posix_spawn_file_actions_t?
    func check(_ result: Int32) throws {
      guard result == 0 else {
        throw MeterError.connection("Cannot start the configured CLI executable.")
      }
    }
    try check(posix_spawnattr_init(&attributes))
    defer { posix_spawnattr_destroy(&attributes) }
    try check(posix_spawn_file_actions_init(&actions))
    defer { posix_spawn_file_actions_destroy(&actions) }
    // A zero group ID assigns the child's own PID before exec, without a race.
    try check(posix_spawnattr_setpgroup(&attributes, 0))
    try check(
      posix_spawnattr_setflags(
        &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
    try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
    // Standard streams intentionally survive exec so CLI descendants can report
    // output. A descendant that leaves our group may retain these descriptors.
    try check(posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO))
    try check(posix_spawn_file_actions_adddup2(&actions, errors, STDERR_FILENO))
    // The _np variant also exists in SDKs for our macOS 13 deployment target.
    try check(posix_spawn_file_actions_addchdir_np(&actions, directory))
    var argv = ([executable] + arguments).map { strdup($0) } + [nil]
    var envp =
      environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      for pointer in argv { free(pointer) }
      for pointer in envp { free(pointer) }
    }
    guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil })
    else {
      throw MeterError.connection("Cannot allocate CLI launch arguments.")
    }
    var child: pid_t = 0
    try check(posix_spawn(&child, executable, &actions, &attributes, &argv, &envp))
    pid = child
  }

  func pollStatus() throws -> Int32? {
    lock.lock()
    defer { lock.unlock() }
    if let status { return status }
    guard let pid else { return nil }
    // Reserve the leader's PID until group escalation, even if TERM made it exit.
    if stopping && !escalated { return nil }
    var value: Int32 = 0
    let result = waitpid(pid, &value, WNOHANG)
    if result == 0 || (result == -1 && errno == EINTR) { return nil }
    guard result == pid else {
      if result == -1 && errno == ECHILD { self.pid = nil }
      throw MeterError.connection("Cannot wait for the CLI executable.")
    }
    status = Self.exitStatus(value)
    return status
  }

  func stop() {
    lock.lock()
    defer { lock.unlock() }
    cancelled = true
    guard pid != nil, status == nil, !stopping else { return }
    stopping = true
    Self.terminationSignals.enter()
    // Keep the leader unreaped until escalation, even if it exits on SIGTERM:
    // grandchildren that ignore SIGTERM still receive the group SIGKILL.
    signal(SIGTERM)
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15) {
      self.escalate()
    }
  }

  // Called only while locked and while the child remains unreaped.
  private func signal(_ value: Int32) {
    guard let pid else { return }
    let groupSignaled = kill(-pid, value) == 0
    // The group signal already reaches its leader. Signal the PID separately
    // only if the group is gone or the child moved to another process group.
    if !groupSignaled || getpgid(pid) != pid { kill(pid, value) }
  }

  private func escalate() {
    lock.lock()
    signal(SIGKILL)
    escalated = true
    // Bound reaping: a child that survives SIGKILL must not poll forever.
    reapDeadline = Date().addingTimeInterval(Self.reapTimeLimit)
    lock.unlock()
    Self.terminationSignals.leave()
    reapLater()
  }

  private func reapLater() {
    // Never block an actor, the main thread, or a dispatch worker in waitpid.
    // Uninterruptible I/O can delay exit after KILL; retain ownership and retry.
    do {
      if try pollStatus() != nil { return }
    } catch { return }
    lock.lock()
    let expired = reapDeadline.map { Date() >= $0 } ?? false
    if expired {
      // Give up ownership after the bound: the zombie stays with the kernel until
      // our process exits and it is reparented; no further polling or signaling.
      pid = nil
    }
    lock.unlock()
    if expired { return }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
      self.reapLater()
    }
  }

  private static func exitStatus(_ value: Int32) -> Int32 {
    let signal = value & 0x7f
    return signal == 0 ? (value >> 8) & 0xff : signal
  }
}

public struct ProcessRunner: CommandRunning {
  public init() {}
  public func run(executable: String, arguments: [String], timeout: TimeInterval = 30) async throws
    -> CommandResult
  {
    let control = ProcessControl()
    return try await withTaskCancellationHandler {
      let worker = Task.detached {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(
          "llm-meter-\(UUID().uuidString)")
        try manager.createDirectory(
          at: directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        for url in [outputURL, errorURL] {
          guard
            manager.createFile(
              atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
          else {
            throw MeterError.connection("Cannot create a temporary output file.")
          }
        }
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer {
          try? output.close()
          try? errors.close()
        }
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CLAUDECODE")
        environment["NO_COLOR"] = "1"
        environment["PATH"] = Self.searchPaths.joined(separator: ":")
        try control.launch(
          executable: executable, arguments: arguments, environment: environment,
          directory: directory.path, output: output.fileDescriptor, errors: errors.fileDescriptor)
        defer { control.stop() }
        let deadline = Date().addingTimeInterval(timeout)
        let status: Int32
        while true {
          if control.isCancelled { throw MeterError.cancelled }
          if let result = try control.pollStatus() {
            status = result
            break
          }
          if Date() >= deadline {
            control.stop()
            throw MeterError.timeout
          }
          let sizes = [outputURL, errorURL].map {
            (try? manager.attributesOfItem(atPath: $0.path)[.size] as? NSNumber)?.intValue ?? 0
          }
          if sizes.contains(where: { $0 > 1_000_000 }) {
            control.stop()
            throw MeterError.malformed("CLI output exceeded the size limit.")
          }
          try await Task.sleep(for: .milliseconds(20))
        }
        for url in [outputURL, errorURL] {
          let size =
            (try manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
          guard size <= 1_000_000 else {
            throw MeterError.malformed("CLI output exceeded the size limit.")
          }
        }
        return CommandResult(
          output: try Data(contentsOf: outputURL), status: status)
      }
      let result = try await worker.value
      try Task.checkCancellation()
      return result
    } onCancel: {
      control.stop()
    }
  }
  /// Wait for pending group KILL signals without waiting on OS process exit.
  /// Call after cancelling source tasks and before completing app termination.
  public static func finishTerminationSignals() async {
    await withCheckedContinuation { continuation in
      ProcessControl.terminationSignals.notify(queue: .global(qos: .utility)) {
        continuation.resume()
      }
    }
  }
  public static var searchPaths: [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return [
      home + "/.local/bin", home + "/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin",
      "/usr/bin", "/bin",
    ]
  }
  public static func executable(_ name: String, configured: String) throws -> String {
    let manager = FileManager.default
    if !configured.isEmpty {
      let path = NSString(string: configured).expandingTildeInPath
      guard manager.isExecutableFile(atPath: path) else {
        throw MeterError.connection(
          ErrorMessage("The configured %@ executable is unavailable.", name))
      }
      return path
    }
    for directory in searchPaths {
      let path = directory + "/" + name
      if manager.isExecutableFile(atPath: path) { return path }
    }
    throw MeterError.connection(
      ErrorMessage("%@ was not found. Choose its executable in Settings.", name))
  }
}
