import AppKit
import LLMMeterCore

@MainActor
enum ProviderIcon {
  private static let resourceBundle: Bundle = {
    if let url = Bundle.main.resourceURL?.appendingPathComponent("LLMMeter_LLMMeterApp.bundle"),
      let bundle = Bundle(url: url)
    {
      return bundle
    }
    return Bundle.module
  }()
  private static let images: [ProviderID: NSImage] = Dictionary(
    uniqueKeysWithValues:
      ProviderID.allCases.map { provider in
        let image =
          resourceBundle.url(
            forResource: provider.rawValue, withExtension: "png",
            subdirectory: "Resources/ProviderIcons"
          )
          .flatMap { NSImage(contentsOf: $0) } ?? MenuBarController.icon()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return (provider, image)
      })

  static func image(_ provider: ProviderID) -> NSImage { images[provider]! }
}
