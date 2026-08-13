// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "ClayHub",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClayHub"
        ),
        .testTarget(
            name: "ClayHubTests",
            dependencies: ["ClayHub"]
        )
    ]
)
