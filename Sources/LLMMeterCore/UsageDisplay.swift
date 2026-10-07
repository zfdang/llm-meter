import Foundation

public enum UsageDisplay {
  public static func resetCountdown(_ resetAt: Date?, now: Date) -> String {
    guard let resetAt else { return "Reset unknown" }
    let seconds = resetAt.timeIntervalSince(now)
    guard seconds > 0 else { return "Awaiting update" }
    if seconds < 60 { return "Resets <1m" }
    return "Resets in \(duration(seconds))"
  }

  public static func updateAge(_ readAt: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(readAt))
    if seconds < 60 { return "Updated just now" }
    return "Updated \(duration(seconds)) ago"
  }

  private static func duration(_ seconds: TimeInterval) -> String {
    // Keep extreme source timestamps compact instead of rendering huge day counts.
    if seconds >= 1000 * 86400 { return "999d+" }
    let minutes = Int(min(seconds / 60, Double(Int.max / 2)))
    let days = minutes / 1440
    let hours = (minutes % 1440) / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes % 60)m" }
    return "\(minutes)m"
  }
}
