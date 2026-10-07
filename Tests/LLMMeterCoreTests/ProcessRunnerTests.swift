import Darwin
import Foundation
import Testing

@testable import LLMMeterCore

@Test func spawnSetsGroupWorkingDirectoryAndExitStatus() async throws {
  let result = try await ProcessRunner().run(
    executable: "/bin/sh",
    arguments: ["-c", "echo $$; /bin/ps -o pgid= -p $$; pwd; exit 7"], timeout: 5)
  let lines = String(decoding: result.output, as: UTF8.self).split(separator: "\n")
  #expect(result.status == 7)
  // Guard index access: restricted hosts can block /bin/ps (empty stdout line).
  guard lines.count >= 2, let shellPID = Int32(lines[0]) else {
    Issue.record("Unexpected shell output: \(lines)")
    return
  }
  #expect(
    URL(fileURLWithPath: String(lines.last ?? "")).lastPathComponent.hasPrefix("llm-meter-"))
  guard let pgid = Int32(lines[1].trimmingCharacters(in: .whitespaces)) else {
    // A restricted host can block /bin/ps, which leaves this line empty; the
    // process-group assertion cannot run there and fails loudly instead of
    // crashing on index access.
    Issue.record("/bin/ps did not report a process group; output: \(lines)")
    return
  }
  #expect(shellPID == pgid)
}

@Test(arguments: [false, true])
func runnerKillsGrandchildWhenLeaderExitsOnTerm(cancel: Bool) async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let pidFile = directory.appendingPathComponent("child.pid")
  let script = """
    trap 'exit 0' TERM
    /bin/sh -c 'trap "" TERM; echo $$ > "$1"; while :; do /bin/sleep 1; done' child "$1" &
    wait
    """
  let runner = ProcessRunner()
  let task = Task {
    try await runner.run(
      executable: "/bin/sh", arguments: ["-c", script, "parent", pidFile.path],
      timeout: cancel ? 20 : 1)
  }
  defer { task.cancel() }
  let deadline = Date().addingTimeInterval(5)
  var childPID: Int32?
  while childPID == nil, Date() < deadline {
    if let text = try? String(contentsOf: pidFile, encoding: .utf8) {
      childPID = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if childPID == nil { try await Task.sleep(for: .milliseconds(20)) }
  }
  let pid = try #require(childPID)
  if cancel { task.cancel() }
  do {
    _ = try await task.value
    Issue.record("An interrupted subprocess unexpectedly succeeded")
  } catch {
    if !cancel { #expect(error as? MeterError == .timeout) }
  }
  await ProcessRunner.finishTerminationSignals()
  let result = try await runner.run(
    executable: "/bin/ps", arguments: ["-o", "stat=,command=", "-p", String(pid)], timeout: 5)
  let state = String(decoding: result.output, as: UTF8.self).trimmingCharacters(
    in: .whitespacesAndNewlines)
  // launchd may not have reaped the orphan yet, but it must no longer be alive.
  #expect(state.isEmpty || state.hasPrefix("Z"))
  // A broken implementation must not leak the test fixture. Confirm its unique
  // command argument before signaling; never signal a PID that may be reused.
  if !state.hasPrefix("Z"), state.contains(pidFile.path) { kill(pid, SIGKILL) }
}

@Test func failedSpawnDoesNotPoisonTheNextRun() async throws {
  let runner = ProcessRunner()
  await #expect(throws: MeterError.self) {
    try await runner.run(executable: "/nonexistent/llm-meter-test", arguments: [], timeout: 1)
  }
  let result = try await runner.run(executable: "/usr/bin/printf", arguments: ["ready"], timeout: 5)
  #expect(result.status == 0)
  #expect(String(decoding: result.output, as: UTF8.self) == "ready")
}

@Test func cancellingSeveralProcessesDoesNotWaitForEachGracePeriod() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let files = (0..<4).map { directory.appendingPathComponent("ready-\($0)") }
  let runner = ProcessRunner()
  let tasks = files.map { file in
    Task {
      try await runner.run(
        executable: "/bin/sh",
        arguments: [
          "-c", "trap '' TERM; echo $$ > \"$1\"; exec /bin/sleep 20", "child", file.path,
        ],
        timeout: 30)
    }
  }
  defer { for task in tasks { task.cancel() } }
  let deadline = Date().addingTimeInterval(5)
  var ready = false
  while !ready, Date() < deadline {
    ready = files.allSatisfy { file in
      guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
      return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }
    if !ready { try await Task.sleep(for: .milliseconds(20)) }
  }
  try #require(ready)
  let start = Date()
  for task in tasks { task.cancel() }
  // The old serial cancellation path spent at least 4 × 150 ms here.
  #expect(Date().timeIntervalSince(start) < 0.3)
  for task in tasks {
    do {
      _ = try await task.value
      Issue.record("A cancelled subprocess unexpectedly succeeded")
    } catch {}
  }
  await ProcessRunner.finishTerminationSignals()
}
