// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ImageResizer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ImageResizer", targets: ["ImageResizer"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "ImageResizer",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                // FoundationModels does not exist before macOS 26 and the deployment
                // target is 14, so a strong link would stop dyld launching the app on
                // every older system. The toolchain already weak-links it, given the
                // availability annotations — verified with otool both with and without
                // this flag — so it is insurance against those guards being loosened
                // later, not the thing making it work today.
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])
            ]
        )
    ]
)
