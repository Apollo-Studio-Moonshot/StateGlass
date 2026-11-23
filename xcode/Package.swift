// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StateGlass",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "StateGlass", targets: ["StateGlass"]),
    ],
    targets: [
        .executableTarget(
            name: "StateGlass",
            path: "Sources/StateGlass",
            resources: [.copy("Icons")]
        ),
    ]
)
