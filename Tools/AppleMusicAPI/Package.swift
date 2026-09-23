// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AMHelper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AMHelper",
            path: "Sources/AMHelper"
        )
    ]
)
