// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ImageResizer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ImageResizer", targets: ["ImageResizer"])
    ],
    targets: [
        .executableTarget(name: "ImageResizer")
    ]
)
