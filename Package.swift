// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Funk",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Funk",
            path: "Sources/Funk"
        )
    ],
    swiftLanguageVersions: [.v5]
)
