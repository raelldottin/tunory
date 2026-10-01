// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TunoryCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "TunoryCore", targets: ["TunoryCore"])
    ],
    targets: [
        .target(
            name: "TunoryCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TunoryCoreTests",
            dependencies: ["TunoryCore"],
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
