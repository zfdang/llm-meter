import Foundation
import Testing

@testable import LLMMeterCore

@Test func languageSelectionHonorsOnlyFirstPreferenceAndChineseScript() {
  for language in ["zh-Hans", "zh-Hans-CN", "zh-CN", "zh-SG"] {
    #expect(L10n.usesSimplifiedChinese([language, "en"]))
    #expect(L10n.text("Refresh", languages: [language]) == "刷新")
  }
  for language in ["en", "ja", "zh-Hant", "zh-TW", "zh-HK", "zh-Hant-CN"] {
    #expect(!L10n.usesSimplifiedChinese([language, "zh-Hans"]))
    #expect(L10n.text("Refresh", languages: [language]) == "Refresh")
  }
  #expect(!L10n.usesSimplifiedChinese([]))
  #expect(L10n.text("Provider-supplied model", languages: ["zh-Hans"]) == "Provider-supplied model")
}

@Test func translatedFormatsPreserveArgumentsAndEnglishFallback() {
  #expect(L10n.format("%@ minutes", "3", languages: ["zh-Hans"]) == "3 分钟")
  #expect(L10n.format("%@ minutes", "3", languages: ["de"]) == "3 minutes")
  #expect(L10n.format("%@h %@m", "%@", "5", languages: ["zh-Hans"]) == "%@ 小时 5 分钟")
}

@Test(arguments: [
  (49.9, UsageTone.low), (50.0, .medium), (79.9, .medium), (80.0, .high), (105.0, .high),
])
func usageTonesFollowConsumptionAndRequireFreshConfirmedValues(used: Double, expected: UsageTone) {
  let now = Date()
  var metric = UsageMetric(
    id: "fixture", name: "Quota", period: .fiveHours, usedPercent: used, readAt: now)
  var state = ServiceState()
  #expect(state.tone(metric, now: now, interval: 180) == .unknown)
  state.confirmed = true
  #expect(state.tone(metric, now: now, interval: 180) == expected)
  state.error = .network
  #expect(state.tone(metric, now: now, interval: 180) == .unknown)
  state.error = nil
  metric.pendingConfirmation = true
  #expect(state.tone(metric, now: now, interval: 180) == .unknown)
  metric.pendingConfirmation = false
  #expect(state.tone(metric, now: now.addingTimeInterval(601), interval: 180) == .unknown)
  metric.resetAt = now
  #expect(state.tone(metric, now: now, interval: 180) == .unknown)
}
