// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "MacProcess",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "MacProcess", targets: ["MacProcess"])
    ],
    targets: [
        .executableTarget(
            name: "MacProcess",
            path: "ProcessControlApp",
            resources: [
                .process("Assets.xcassets")
            ]
        )
    ]
)
