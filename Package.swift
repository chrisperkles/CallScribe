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
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
