import Foundation
import CoreGraphics

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
        exit(1)
    }
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
    ResizeMath.fittedSize(source: CGSize(width: 500, height: 250), width: 2000, height: 2000)
        == CGSize(width: 2000, height: 1000),
    "upscaling"
)
check(
    ResizeMath.fittedSize(source: CGSize(width: 400, height: 200), width: nil, height: 100)
        == CGSize(width: 200, height: 100),
    "single dimension"
)
check(
    JobPlanner.relativePath(
        of: URL(fileURLWithPath: "/Photos/Trips/Paris/image.jpg"),
        beneath: URL(fileURLWithPath: "/Photos")
    ) == "Trips/Paris/image.jpg",
    "folder structure"
)

print("All Image Resizer checks passed.")
