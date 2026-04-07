// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mpd",
    // Minimum deployment target: macOS 14 Sonoma
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "mpd",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: ".",
            exclude: [
                "bin", "conf",
                "assets", ".swiftpm", "mpd-machine",
                "docs", "README.md", "LICENSE", "Makefile", "CLAUDE.md", "AGENTS.md"
            ],
            sources: ["mpd"],
            // Swift 5 language mode: opt out of Swift 6 strict concurrency (unnecessary for a single-threaded CLI)
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
