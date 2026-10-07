// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "LLMMeter",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "LLMMeter", targets: ["LLMMeterApp"]),
    .library(name: "LLMMeterCore", targets: ["LLMMeterCore"]),
  ],
  targets: [
    .target(name: "LLMMeterCore"),
    .executableTarget(
      name: "LLMMeterApp", dependencies: ["LLMMeterCore"], resources: [.copy("Resources")]),
    .testTarget(name: "LLMMeterCoreTests", dependencies: ["LLMMeterCore"]),
    .testTarget(name: "LLMMeterAppTests", dependencies: ["LLMMeterApp"]),
  ]
)
