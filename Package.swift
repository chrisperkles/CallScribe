// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CallScribe",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "ObjCExceptionCatcher",
            path: "Sources/ObjCExceptionCatcher"
        ),
        .executableTarget(
            name: "CallScribe",
            dependencies: ["ObjCExceptionCatcher"],
            path: "Sources/CallScribe"
        )
    ]
)
