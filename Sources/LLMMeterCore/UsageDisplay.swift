import Foundation

public enum UsageDisplay {
  public static func resetCountdown(_ resetAt: Date?, now: Date) -> String {
    guard let resetAt else { return L10n.text("Reset unknown") }
    let seconds = resetAt.timeIntervalSince(now)
    guard seconds > 0 else { return L10n.text("Awaiting update") }
    if seconds < 60 { return L10n.text("Resets <1m") }
    return L10n.format("Resets in %@", duration(seconds))
  }

  public static func updateAge(_ readAt: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(readAt))
    if seconds < 60 { return L10n.text("Updated just now") }
    return L10n.format("Updated %@ ago", duration(seconds))
  }

  private static func duration(_ seconds: TimeInterval) -> String {
    // Keep extreme source timestamps compact instead of rendering huge day counts.
    if seconds >= 1000 * 86400 { return L10n.text("999d+") }
    let minutes = Int(min(seconds / 60, Double(Int.max / 2)))
    let days = minutes / 1440
    let hours = (minutes % 1440) / 60
    if days > 0 { return L10n.format("%@d %@h", String(days), String(hours)) }
    if hours > 0 { return L10n.format("%@h %@m", String(hours), String(minutes % 60)) }
    return L10n.format("%@m", String(minutes))
  }
}
