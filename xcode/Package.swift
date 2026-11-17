// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StateGlass",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "StateGlass", targets: ["StateGlass"]),
    ],
    targets: [
        .executableTarget(
            name: "StateGlass",
            path: "Sources/StateGlass"
        ),
    ]
)
