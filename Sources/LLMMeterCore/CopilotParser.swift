import CoreFoundation
import Foundation

public enum CopilotParser {
  public static func parse(_ data: Data, accountID: String, accountLabel: String, now: Date) throws
    -> UsageSnapshot
  {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let quotas = root["quota_snapshots"] as? [String: [String: Any]]
    else {
      throw MeterError.malformed("Unrecognized Copilot quota response.")
    }
    let reset =
      (root["quota_reset_date_utc"] as? String).flatMap(UsageParsers.isoDate)
      ?? (root["quota_reset_date"] as? String).flatMap { UsageParsers.isoDate($0 + "T00:00:00Z") }
    var metrics: [UsageMetric] = []
    for id in ["premium_interactions", "chat", "completions"] {
      guard let quota = quotas[id] else { continue }
      let credits =
        quota["token_based_billing"] as? Bool ?? root["token_based_billing"] as? Bool ?? false
      let name =
        id == "premium_interactions"
        ? (credits ? "AI Credits" : "Premium requests")
        : (id == "chat" ? "Chat requests" : "Completions")
      let limit = number(quota["entitlement"])
      let remaining = number(quota["quota_remaining"])
      let percent = number(quota["percent_remaining"])
      let reportedUnlimited = quota["unlimited"] as? Bool == true
      // A managed premium pool can report unlimited while denying quota availability.
      let unavailablePool =
        id == "premium_interactions" && reportedUnlimited && quota["has_quota"] as? Bool == false
      let unlimited = reportedUnlimited && !unavailablePool
      var used: Double?
      if !unlimited && !unavailablePool {
        if let limit, limit > 0, let remaining {
          used = max(0, (limit - remaining) / limit * 100)
        } else if let percent, (0...100).contains(percent), limit != 0 {
          used = 100 - percent
        }
      }
      let resetAt =
        number(quota["quota_reset_at"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        ?? reset
      metrics.append(
        .init(
          id: id, name: name, period: .monthly, usedPercent: used,
          resetAt: unlimited ? nil : resetAt, readAt: now, unlimited: unlimited,
          unit: id == "premium_interactions" && credits
            ? "AI credits" : (id == "completions" ? "completions" : "requests"),
          limit: limit, remaining: remaining))
    }
    guard !metrics.isEmpty else {
      throw MeterError.unsupported("Copilot did not report any supported quota snapshots.")
    }
    return .init(
      provider: .copilot, accountID: accountID, accountLabel: accountLabel,
      plan: root["copilot_plan"] as? String, metrics: metrics, readAt: now)
  }

  private static func number(_ value: Any?) -> Double? {
    let result: Double?
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
      result = number.doubleValue
    } else if let text = value as? String {
      result = Double(text)
    } else {
      result = nil
    }
    return result.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
  }
}
