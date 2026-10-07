import Foundation

public enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
  case codex, claude, antigravity, copilot
  public var id: String { rawValue }
  public var name: String {
    switch self {
    case .codex: "Codex"
    case .claude: "Claude Code"
    case .antigravity: "Antigravity"
    case .copilot: "GitHub Copilot"
    }
  }
  public var abbreviation: String {
    switch self {
    case .codex: "CX"
    case .claude: "CC"
    case .antigravity: "AG"
    case .copilot: "CP"
    }
  }
  public var minimumInterval: TimeInterval { self == .claude ? 300 : 60 }
  public var manualInterval: TimeInterval { self == .claude ? 30 : 15 }
}

public enum MetricPeriod: String, Codable, Sendable { case fiveHours, weekly, monthly, other }

public struct UsageMetric: Codable, Identifiable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var period: MetricPeriod
  public var scope: String?
  public var usedPercent: Double?
  public var resetAt: Date?
  public var readAt: Date
  public var pendingConfirmation: Bool = false
  public var unlimited: Bool = false
  public var unit: String?
  public var limit: Double?
  public var remaining: Double?
  private enum CodingKeys: String, CodingKey {
    case id, name, period, scope, usedPercent, resetAt, readAt, pendingConfirmation, unlimited,
      unit, limit, remaining
  }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    period = try values.decode(MetricPeriod.self, forKey: .period)
    scope = try values.decodeIfPresent(String.self, forKey: .scope)
    usedPercent = try values.decodeIfPresent(Double.self, forKey: .usedPercent)
    resetAt = try values.decodeIfPresent(Date.self, forKey: .resetAt)
    readAt = try values.decode(Date.self, forKey: .readAt)
    pendingConfirmation =
      try values.decodeIfPresent(Bool.self, forKey: .pendingConfirmation) ?? false
    unlimited = try values.decodeIfPresent(Bool.self, forKey: .unlimited) ?? false
    unit = try values.decodeIfPresent(String.self, forKey: .unit)
    limit = try values.decodeIfPresent(Double.self, forKey: .limit)
    remaining = try values.decodeIfPresent(Double.self, forKey: .remaining)
  }
  public init(
    id: String, name: String, period: MetricPeriod = .other, scope: String? = nil,
    usedPercent: Double?, resetAt: Date? = nil, readAt: Date,
    unlimited: Bool = false, unit: String? = nil, limit: Double? = nil, remaining: Double? = nil
  ) {
    self.id = id
    self.name = name
    self.period = period
    self.scope = scope
    self.usedPercent = usedPercent
    self.resetAt = resetAt
    self.readAt = readAt
    self.unlimited = unlimited
    self.unit = unit
    self.limit = limit
    self.remaining = remaining
  }
  public func percent(remaining: Bool) -> Double? {
    guard !unlimited, let usedPercent, usedPercent.isFinite, usedPercent >= 0 else { return nil }
    return remaining ? max(0, 100 - usedPercent) : usedPercent
  }
  public func awaitingReset(at now: Date) -> Bool { resetAt.map { $0 <= now } ?? false }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
  public var provider: ProviderID
  public var accountID: String
  public var accountLabel: String
  public var plan: String?
  public var metrics: [UsageMetric]
  public var readAt: Date
  public var complete: Bool
  public init(
    provider: ProviderID, accountID: String, accountLabel: String, plan: String? = nil,
    metrics: [UsageMetric], readAt: Date, complete: Bool = true
  ) {
    self.provider = provider
    self.accountID = accountID
    self.accountLabel = accountLabel
    self.plan = plan
    self.metrics = metrics
    self.readAt = readAt
    self.complete = complete
  }
  public func merging(previous: UsageSnapshot?) -> UsageSnapshot {
    guard !complete, let previous, previous.accountID == accountID else { return self }
    var result = self
    let reported = Set(metrics.map(\.id))
    result.metrics += previous.metrics.filter { !reported.contains($0.id) }.map {
      var metric = $0
      metric.pendingConfirmation = true
      return metric
    }
    return result
  }
}

public struct ServiceConfiguration: Codable, Equatable, Identifiable, Sendable {
  public var provider: ProviderID
  public var enabled: Bool = true
  public var visible: Bool = true
  public var sourcePath: String = ""
  public var id: ProviderID { provider }
  public init(provider: ProviderID, sourcePath: String = "") {
    self.provider = provider
    self.sourcePath = sourcePath
  }
}

public struct AppSettings: Codable, Equatable, Sendable {
  public var schemaVersion: Int = 1
  public var services: [ServiceConfiguration] = ProviderID.allCases.map { .init(provider: $0) }
  public var showUsage: Bool = false
  public var selectedProvider: ProviderID = .codex
  public var selectedMetricID: String = "primary"
  public var selectedAccountID: String? = nil
  public var showRemaining: Bool = false
  public var refreshMinutes: Int = 3
  public init() {}
  public func active(_ service: ServiceConfiguration) -> Bool {
    service.enabled && (service.visible || (showUsage && selectedProvider == service.provider))
  }
  public func validate() throws {
    guard schemaVersion == 1 else {
      throw MeterError.storage("Unsupported settings version. Original file preserved.")
    }
    guard [1, 3, 5, 10].contains(refreshMinutes),
      Set(services.map(\.provider)).count == services.count,
      Set(services.map(\.provider)) == Set(ProviderID.allCases)
    else {
      throw MeterError.storage("Invalid settings. Original file preserved.")
    }
  }
}

public enum MeterError: Error, LocalizedError, Equatable, Sendable {
  case connection(String)
  case authentication(String)
  case unsupported(String)
  case malformed(String)
  case rateLimited(TimeInterval)
  case network, timeout, cancelled
  case storage(String)
  public var errorDescription: String? {
    switch self {
    case .connection(let text), .authentication(let text), .unsupported(let text),
      .malformed(let text), .storage(let text):
      text
    case .rateLimited: "Rate limited. Waiting before retrying."
    case .network: "Could not reach the usage source."
    case .timeout: "The usage source timed out."
    case .cancelled: "Refresh cancelled."
    }
  }
}

public enum Freshness: Sendable { case fresh, stale, expired, awaitingReset }

public struct ServiceState: Sendable {
  private static let expiryIntervalMultiplier: TimeInterval = 4
  private static let minimumExpiryAge: TimeInterval = 1800
  private static let staleIntervalMultiplier: TimeInterval = 2
  private static let minimumStaleAge: TimeInterval = 600
  public var snapshot: UsageSnapshot?
  public var error: MeterError?
  public var refreshing = false
  public var confirmed = false
  public var nextRefresh = Date.distantPast
  public init(snapshot: UsageSnapshot? = nil) { self.snapshot = snapshot }
  public func freshness(_ metric: UsageMetric, now: Date, interval: TimeInterval) -> Freshness {
    if metric.awaitingReset(at: now) { return .awaitingReset }
    let age = now.timeIntervalSince(metric.readAt)
    if age >= max(Self.expiryIntervalMultiplier * interval, Self.minimumExpiryAge) {
      return .expired
    }
    if !confirmed || metric.pendingConfirmation || error != nil
      || age >= max(Self.staleIntervalMultiplier * interval, Self.minimumStaleAge)
    {
      return .stale
    }
    return .fresh
  }
  public func label(_ metric: UsageMetric?, now: Date, interval: TimeInterval, remaining: Bool)
    -> String
  {
    guard let metric else { return "—" }
    let status = freshness(metric, now: now, interval: interval)
    if status == .expired || status == .awaitingReset { return "—" }
    if metric.unlimited { return status == .stale ? "Unlimited·" : "Unlimited" }
    guard let value = metric.percent(remaining: remaining) else { return "—" }
    return String(format: "%.0f%%%@", value, status == .stale ? "·" : "")
  }
}
