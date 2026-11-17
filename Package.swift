// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Iine",
    platforms: [.macOS(.v12)],
    targets: [
        .target(
            name: "IineCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Iine",
            dependencies: ["IineCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "snip",
            dependencies: ["IineCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "IineCoreTests",
            dependencies: ["IineCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
