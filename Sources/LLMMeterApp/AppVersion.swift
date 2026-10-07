import Foundation

/// Read the running bundle, including the release stamp supplied during packaging.
struct AppVersion {
  static let current = AppVersion(infoDictionary: Bundle.main.infoDictionary)

  let version: String?
  let build: String?

  init(infoDictionary: [String: Any]?) {
    func value(_ key: String) -> String? {
      guard let text = infoDictionary?[key] as? String else { return nil }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    version = value("CFBundleShortVersionString")
    build = value("CFBundleVersion")
  }
}
