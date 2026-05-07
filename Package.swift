// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "SideClick",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SideClick"
        ),
        .testTarget(
            name: "SideClickTests",
            dependencies: ["SideClick"]
        )
    ]
)
