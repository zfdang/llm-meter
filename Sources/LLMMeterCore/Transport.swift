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

/// Owns a single subprocess. The lock protects cancellation before and during launch.
private final class ProcessControl: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var cancelled = false
  func launch(_ process: Process) throws {
    lock.lock()
    defer { lock.unlock() }
    if cancelled { throw MeterError.cancelled }
    self.process = process
    try process.run()
    // Only signal a group if the child actually owns it.
    _ = setpgid(process.processIdentifier, process.processIdentifier)
  }
  func stop() {
    lock.lock()
    cancelled = true
    let process = process
    lock.unlock()
    guard let process, process.isRunning else { return }
    let pid = process.processIdentifier
    let target = getpgid(pid) == pid ? -pid : pid
    kill(target, SIGTERM)
    Thread.sleep(forTimeInterval: 0.15)
    if process.isRunning { kill(target, SIGKILL) }
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CLAUDECODE")
        environment["NO_COLOR"] = "1"
        environment["PATH"] = Self.searchPaths.joined(separator: ":")
        process.environment = environment
        do { try control.launch(process) } catch let error as MeterError { throw error } catch {
          throw MeterError.connection("Cannot start the configured CLI executable.")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
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
        process.waitUntilExit()
        for url in [outputURL, errorURL] {
          let size =
            (try manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
          guard size <= 1_000_000 else {
            throw MeterError.malformed("CLI output exceeded the size limit.")
          }
        }
        return CommandResult(
          output: try Data(contentsOf: outputURL), status: process.terminationStatus)
      }
      let result = try await worker.value
      try Task.checkCancellation()
      return result
    } onCancel: {
      control.stop()
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
        throw MeterError.connection("The configured \(name) executable is unavailable.")
      }
      return path
    }
    for directory in searchPaths {
      let path = directory + "/" + name
      if manager.isExecutableFile(atPath: path) { return path }
    }
    throw MeterError.connection("\(name) was not found. Choose its executable in Settings.")
  }
}
