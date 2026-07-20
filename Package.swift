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
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
