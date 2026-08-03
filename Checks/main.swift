import Foundation
import CoreGraphics

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
        exit(1)
    }
}

private func settings(
    mode: ResizeMode,
    width: Int? = nil,
    height: Int? = nil,
    longEdge: Int? = nil,
    percentage: Int? = nil,
    preventEnlargement: Bool = false
) -> ResizeSettings {
    ResizeSettings(
        mode: mode,
        width: width,
        height: height,
        longEdge: longEdge,
        percentage: percentage,
        preventEnlargement: preventEnlargement,
        filenameSuffix: "-resized",
        format: .jpeg,
        quality: 0.9,
        targetFileSizeEnabled: false,
        targetFileSizeBytes: nil,
        preserveMetadata: true,
        removeLocation: true,
        backgroundRed: 1,
        backgroundGreen: 1,
        backgroundBlue: 1,
        useCustomDestination: false,
        customDestination: nil
    )
}

check(
    ResizeMath.fittedSize(source: CGSize(width: 4000, height: 2000), width: 2000, height: 2000)
        == CGSize(width: 2000, height: 1000),
    "landscape bounding box"
)
check(
    ResizeMath.fittedSize(source: CGSize(width: 1000, height: 2000), width: 2000, height: 2000)
        == CGSize(width: 1000, height: 2000),
    "portrait bounding box"
)
check(
    ResizeMath.fittedSize(
        source: CGSize(width: 500, height: 250),
        width: 2000,
        height: 2000,
        preventEnlargement: true
    )
        == CGSize(width: 500, height: 250),
    "prevent upscaling"
)
check(
    ResizeMath.fittedSize(
        source: CGSize(width: 500, height: 250),
        width: 2000,
        height: 2000,
        preventEnlargement: false
    )
        == CGSize(width: 2000, height: 1000),
    "allow upscaling"
)
check(
    ResizeMath.fittedSize(source: CGSize(width: 400, height: 200), width: nil, height: 100)
        == CGSize(width: 200, height: 100),
    "single dimension"
)
check(
    ResizeMath.layout(
        source: CGSize(width: 4000, height: 2000),
        settings: settings(mode: .fill, width: 1000, height: 1000)
    ) == ResizeLayout(
        outputSize: CGSize(width: 1000, height: 1000),
        drawRect: CGRect(x: -500, y: 0, width: 2000, height: 1000)
    ),
    "fill and center crop"
)
check(
    ResizeMath.layout(
        source: CGSize(width: 4000, height: 2000),
        settings: settings(mode: .longEdge, longEdge: 1000)
    ).outputSize == CGSize(width: 1000, height: 500),
    "long edge"
)
check(
    ResizeMath.layout(
        source: CGSize(width: 4000, height: 2000),
        settings: settings(mode: .percentage, percentage: 50)
    ).outputSize == CGSize(width: 2000, height: 1000),
    "percentage"
)
check(
    ResizeMath.layout(
        source: CGSize(width: 500, height: 250),
        settings: settings(mode: .percentage, percentage: 200, preventEnlargement: true)
    ).outputSize == CGSize(width: 500, height: 250),
    "percentage respects no-enlargement"
)
check(
    JobPlanner.relativePath(
        of: URL(fileURLWithPath: "/Photos/Trips/Paris/image.jpg"),
        beneath: URL(fileURLWithPath: "/Photos")
    ) == "Trips/Paris/image.jpg",
    "folder structure"
)
let namedJob = ResizeJob(
    source: URL(fileURLWithPath: "/Photos/image.png"),
    destination: URL(fileURLWithPath: "/Exports/image.png")
)
check(
    namedJob.requestedOutputURL(extension: "jpg", filenameSuffix: "-resized").lastPathComponent == "image-resized.jpg",
    "filename suffix"
)
check(
    namedJob.requestedOutputURL(extension: "jpg", filenameSuffix: "").lastPathComponent == "image.jpg",
    "blank filename suffix"
)
check(
    namedJob.requestedOutputURL(extension: "jpg", filenameSuffix: "/web:\n").lastPathComponent == "image-web--.jpg",
    "safe filename suffix"
)
check(FileSizeUnit.kilobytes.bytes(for: 500) == 512_000, "kilobyte target")
check(FileSizeUnit.megabytes.bytes(for: 2) == 2_097_152, "megabyte target")
check(FileSizeUnit.kilobytes.bytes(for: 0) == nil, "invalid target")
var targetSettings = settings(mode: .fit, width: 1_000)
targetSettings.targetFileSizeEnabled = true
targetSettings.targetFileSizeBytes = 512_000
check(targetSettings.isValid, "JPEG target settings")
targetSettings.format = .png
check(!targetSettings.isValid, "unsupported target format")
targetSettings.format = .webp
targetSettings.targetFileSizeBytes = nil
check(!targetSettings.isValid, "missing target size")

print("All Image Resizer checks passed.")
