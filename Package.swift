// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CallScribe",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(
            name: "ObjCExceptionCatcher",
            path: "Sources/ObjCExceptionCatcher"
        ),
        .executableTarget(
            name: "CallScribe",
            dependencies: ["ObjCExceptionCatcher", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/CallScribe",
            linkerSettings: [
                // Sparkle.framework is copied into the bundle by build.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                // Apple Intelligence titles (macOS 26+). Weak, so the app still
                // launches on macOS 15, where the framework doesn't exist.
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])
            ]
        )
    ]
)
