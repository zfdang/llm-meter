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

@Test func errorMessagesTranslateOnceAtPresentation() {
  let message = ErrorMessage("Cannot read %@. Original file preserved.", "settings.json")
  #expect(message.localized(languages: ["zh-Hans"]) == "无法读取 settings.json。原文件已保留。")
  #expect(
    message.localized(languages: ["en"]) == "Cannot read settings.json. Original file preserved.")
  let literal: ErrorMessage = "Could not render the screenshot."
  #expect(literal.localized(languages: ["zh-Hans"]) == "无法渲染截图。")
}

@Test func malformedFormatsPreserveArguments() {
  #expect(L10n.interpolate("Resets in %@", translated: "即将重置", arguments: ["3m"]) == "Resets in 3m")
  #expect(L10n.format("Refresh", "extra", languages: ["zh-Hans"]) == "刷新 extra")
  #expect(L10n.format("%@h %@m", "1", languages: ["en"]) == "1h %@m")
  #expect(!L10n.usesSimplifiedChinese(["zh"]))  // An unspecified script stays English.
}

/// Checks literal UI/error keys in both targets, without treating API/model names
/// passed dynamically to text() as catalog keys. No provider requests are made.
@Test func translationCatalogCoversSourceLiteralsAndHasNoUnusedKeys() throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let sources = root.appendingPathComponent("Sources")
  let enumerator = try #require(
    FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
  let literal = #""(?:\\.|[^"\\])*""#
  let pattern =
    #"(?:L10n\.(?:text|format)|ErrorMessage|(?:MeterError\.)?(?:connection|authentication|unsupported|malformed|storage))\(\s*("#
    + literal + ")"
  let calls = try NSRegularExpression(pattern: pattern)
  var required = Set<String>()
  var sourceText = ""
  for case let url as URL in enumerator
  where url.pathExtension == "swift" && url.lastPathComponent != "Localization.swift" {
    let source = try String(contentsOf: url, encoding: .utf8)
    sourceText += source
    let text = source as NSString
    for match in calls.matches(in: source, range: NSRange(location: 0, length: text.length)) {
      let quoted = text.substring(with: match.range(at: 1))
      let key = try JSONDecoder().decode(String.self, from: Data(quoted.utf8))
      required.insert(key)
    }
  }
  #expect(!required.isEmpty)
  let keys = Set(L10n.translations.keys)
  #expect(
    required.subtracting(keys).isEmpty,
    "Missing translations: \(required.subtracting(keys).sorted())")
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.withoutEscapingSlashes]
  for (key, translation) in L10n.translations {
    let quoted = String(decoding: try encoder.encode(key), as: UTF8.self)
    #expect(sourceText.contains(quoted) == true, "Unused translation: \(key)")
    #expect(!translation.isEmpty, "Empty translation: \(key)")
    #expect(
      key.components(separatedBy: "%@").count == translation.components(separatedBy: "%@").count,
      "Placeholder mismatch: \(key)")
  }
}
