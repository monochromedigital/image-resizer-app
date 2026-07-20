import Testing
@testable import ImageResizer

@Suite("Image Resizer")
struct ImageResizerTests {
    @Test func landscapeFitsSquare() {
        let result = ResizeMath.fittedSize(source: CGSize(width: 4000, height: 2000), width: 2000, height: 2000)
        #expect(result == CGSize(width: 2000, height: 1000))
    }

    @Test func portraitFitsSquare() {
        let result = ResizeMath.fittedSize(source: CGSize(width: 1000, height: 2000), width: 2000, height: 2000)
        #expect(result == CGSize(width: 1000, height: 2000))
    }

    @Test func smallImageIsEnlarged() {
        let result = ResizeMath.fittedSize(source: CGSize(width: 500, height: 250), width: 2000, height: 2000)
        #expect(result == CGSize(width: 2000, height: 1000))
    }

    @Test func singleDimensionConstraint() {
        #expect(ResizeMath.fittedSize(source: CGSize(width: 400, height: 200), width: nil, height: 100) == CGSize(width: 200, height: 100))
    }

    @Test func relativePathPreservesFolders() {
        let root = URL(fileURLWithPath: "/Photos")
        let file = URL(fileURLWithPath: "/Photos/Trips/Paris/image.jpg")
        #expect(JobPlanner.relativePath(of: file, beneath: root) == "Trips/Paris/image.jpg")
    }
}
