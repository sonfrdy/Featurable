// swift-tools-version: 6.1

import CompilerPluginSupport
import PackageDescription

let package = Package(
  name: "Featurable",
  platforms: [
    .iOS(.v13),
    .macOS(.v10_15),
    .tvOS(.v13),
    .watchOS(.v6)
  ],
  products: [
    .library(
      name: "Featurable",
      targets: ["Featurable"]
    ),
    .library(
      name: "FeaturableTesting",
      targets: ["FeaturableTesting"]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.6.0"),
    .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", from: "1.10.0"),
    .package(url: "https://github.com/swiftlang/swift-syntax", "600.0.0"..<"700.0.0"),
  ],
  targets: [
    .target(
      name: "Featurable",
      dependencies: [
        "FeaturableMacros",
      ]
    ),
    .target(
      name: "FeaturableTesting",
      dependencies: [
        "Featurable",
        .product(name: "CustomDump", package: "swift-custom-dump"),
        .product(name: "IssueReporting", package: "xctest-dynamic-overlay"),
      ]
    ),
    .macro(
      name: "FeaturableMacros",
      dependencies: [
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
      ]
    ),
    .testTarget(
      name: "FeaturableTests",
      dependencies: [
        "Featurable",
        "FeaturableTesting",
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
