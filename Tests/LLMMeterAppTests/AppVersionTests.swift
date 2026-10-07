import Testing

@testable import LLMMeterApp

@Test func appVersionReadsPackagedReleaseMetadata() {
  let version = AppVersion(infoDictionary: [
    "CFBundleShortVersionString": "2026.10.07-bb36f3b",
    "CFBundleVersion": "123456",
  ])
  #expect(version.version == "2026.10.07-bb36f3b")
  #expect(version.build == "123456")
}

@Test func appVersionHandlesMissingDevelopmentMetadata() {
  let absent = AppVersion(infoDictionary: nil)
  #expect(absent.version == nil)
  #expect(absent.build == nil)
  let invalid = AppVersion(infoDictionary: [
    "CFBundleShortVersionString": "  ", "CFBundleVersion": 123,
  ])
  #expect(invalid.version == nil)
  #expect(invalid.build == nil)
}
