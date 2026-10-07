import Foundation

public enum UsageParsers {
  public static func codex(_ data: Data, accountID: String, accountLabel: String, now: Date) throws
    -> UsageSnapshot
  {
    struct Window: Decodable {
      let usedPercent: Double?
      let limitWindowSeconds: Int?
      let resetAt: Double?
      let resetAfterSeconds: Double?
    }
    struct Limits: Decodable {
      let primaryWindow: Window?
      let secondaryWindow: Window?
    }
    struct Reply: Decodable {
      let planType: String?
      let rateLimit: Limits?
    }
    let reply: Reply
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    do { reply = try decoder.decode(Reply.self, from: data) } catch {
      throw MeterError.malformed("Unrecognized Codex usage response.")
    }
    guard let limits = reply.rateLimit else {
      throw MeterError.malformed("Codex did not return quota windows.")
    }
    var metrics: [UsageMetric] = []
    for (id, window) in [
      ("primary", limits.primaryWindow), ("secondary", limits.secondaryWindow),
    ] {
      guard let window else { continue }
      try validate(window.usedPercent)
      let period: MetricPeriod =
        window.limitWindowSeconds == 18_000
        ? .fiveHours : window.limitWindowSeconds == 604_800 ? .weekly : .other
      let reset =
        window.resetAt.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        ?? window.resetAfterSeconds.flatMap {
          $0.isFinite && $0 > 0 ? now.addingTimeInterval($0) : nil
        }
      metrics.append(
        .init(
          id: id, name: period == .fiveHours ? "5h" : period == .weekly ? "Weekly" : "Quota",
          period: period, usedPercent: window.usedPercent, resetAt: reset, readAt: now))
    }
    guard !metrics.isEmpty else {
      throw MeterError.unsupported("No Codex quota windows are available for this account.")
    }
    return .init(
      provider: .codex, accountID: accountID, accountLabel: accountLabel,
      plan: reply.planType, metrics: metrics, readAt: now)
  }

  public static func claude(_ text: String, accountID: String, accountLabel: String, now: Date)
    throws -> UsageSnapshot
  {
    let clean = text.replacingOccurrences(
      of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    if clean.range(
      of:
        "(?i)\\b(401|403)\\b|not (logged|signed) in|signed out|unauthorized|authentication (failed|required)",
      options: .regularExpression) != nil
    {
      throw MeterError.authentication(
        "Claude Code requires sign-in. Run claude in Terminal, then refresh.")
    }
    let expression = try NSRegularExpression(
      pattern:
        "^Current (session|week(?: \\(([^)]+)\\))?):\\s*([0-9.]+)% used(?:\\s*[·•]\\s*resets (.+))?$",
      options: [.anchorsMatchLines])
    let source = clean as NSString
    var metrics: [UsageMetric] = []
    for match in expression.matches(in: clean, range: NSRange(location: 0, length: source.length)) {
      let session = source.substring(with: match.range(at: 1)) == "session"
      let scope =
        match.range(at: 2).location == NSNotFound ? nil : source.substring(with: match.range(at: 2))
      let model = scope.flatMap { $0.lowercased() == "all models" ? nil : $0 }
      guard let used = Double(source.substring(with: match.range(at: 3))) else { continue }
      try validate(used)
      let resetText =
        match.range(at: 4).location == NSNotFound ? "" : source.substring(with: match.range(at: 4))
      let metric = UsageMetric(
        id: session ? "session" : model.map { "week-\($0.lowercased())" } ?? "week",
        name: session ? "5h" : model.map { "Weekly · \($0)" } ?? "Weekly",
        period: session ? .fiveHours : .weekly, scope: model,
        usedPercent: used, resetAt: resetDate(resetText, now: now), readAt: now)
      if !metrics.contains(where: { $0.id == metric.id }) { metrics.append(metric) }
    }
    guard !metrics.isEmpty else {
      throw MeterError.unsupported(
        "Claude Code returned no recognized usage windows. Check its version and sign-in.")
    }
    return .init(
      provider: .claude, accountID: accountID, accountLabel: accountLabel,
      metrics: metrics, readAt: now, complete: false)
  }

  public static func antigravity(_ data: Data, accountID: String, accountLabel: String, now: Date)
    throws -> UsageSnapshot
  {
    struct Quota: Decodable {
      let remainingFraction: Double?
      let resetTime: String?
    }
    struct Model: Decodable {
      let displayName: String?
      let quotaInfo: Quota?
      let disabled: Bool?
    }
    struct Reply: Decodable { let models: [String: Model] }
    let reply: Reply
    do { reply = try JSONDecoder().decode(Reply.self, from: data) } catch {
      throw MeterError.malformed("Unrecognized Antigravity quota response.")
    }
    var metrics: [UsageMetric] = []
    for id in reply.models.keys.sorted() {
      guard let model = reply.models[id], model.disabled != true, let quota = model.quotaInfo,
        !id.hasPrefix("chat_"), !id.hasPrefix("tab_")
      else { continue }
      if let fraction = quota.remainingFraction, !fraction.isFinite || !(0...1).contains(fraction) {
        throw MeterError.malformed("Invalid Antigravity quota fraction.")
      }
      // A reset timestamp alone does not establish the window duration.
      metrics.append(
        .init(
          id: id, name: model.displayName ?? id, scope: id,
          usedPercent: quota.remainingFraction.map { (1 - $0) * 100 },
          resetAt: quota.resetTime.flatMap(isoDate), readAt: now))
    }
    guard !metrics.isEmpty else {
      throw MeterError.unsupported("No Antigravity model quotas were returned.")
    }
    return .init(
      provider: .antigravity, accountID: accountID, accountLabel: accountLabel,
      metrics: metrics, readAt: now)
  }

  public static func isoDate(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions.insert(.withFractionalSeconds)
    return formatter.date(from: text)
  }

  public static func resetDate(_ text: String, now: Date) -> Date? {
    if let date = isoDate(text) { return date }
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    var zone = TimeZone.current
    if let start = value.lastIndex(of: "("), value.hasSuffix(")") {
      let name = String(value[value.index(after: start)..<value.index(before: value.endIndex)])
      guard let parsed = TimeZone(identifier: name) else { return nil }
      zone = parsed
      value = String(value[..<start]).trimmingCharacters(in: .whitespaces)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone
    formatter.isLenient = false
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let year = calendar.component(.year, from: now)
    for format in ["MMM d 'at' h:mma", "MMM d 'at' ha", "MMM d, h:mma", "MMM d, ha"] {
      formatter.dateFormat = "yyyy " + format
      if let date = formatter.date(from: "\(year) \(value)") {
        return date < now.addingTimeInterval(-86_400)
          ? calendar.date(byAdding: .year, value: 1, to: date) : date
      }
    }
    for format in ["MMM d, yyyy 'at' h:mma", "MMM d, yyyy, h:mma", "MMM d, yyyy 'at' ha"] {
      formatter.dateFormat = format
      if let date = formatter.date(from: value) { return date }
    }
    let day = calendar.startOfDay(for: now)
    for format in ["h:mma", "ha"] {
      formatter.dateFormat = format
      if let time = formatter.date(from: value) {
        let components = calendar.dateComponents([.hour, .minute], from: time)
        guard let date = calendar.date(byAdding: components, to: day) else { return nil }
        return date < now ? calendar.date(byAdding: .day, value: 1, to: date) : date
      }
    }
    return nil
  }
  private static func validate(_ number: Double?) throws {
    if let number, !number.isFinite || number < 0 {
      throw MeterError.malformed("The source returned an invalid usage percentage.")
    }
  }
}
