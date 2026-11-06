// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Jietu",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Jietu",
            path: "Sources/Jietu"
        ),
    ],
    swiftLanguageModes: [.v5]
)
