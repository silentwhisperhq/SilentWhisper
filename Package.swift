// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SilentWhisper",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "SilentWhisper",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit")]
        )
    ]
)
