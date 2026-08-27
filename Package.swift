// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CallScribe",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "CallScribe",
            path: "Sources/CallScribe"
        )
    ]
)
