// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MicPause",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MicPauseCore"),
        .executableTarget(name: "MicPause", dependencies: ["MicPauseCore"]),
        .executableTarget(name: "MicPauseCLI", dependencies: ["MicPauseCore"]),
    ]
)
