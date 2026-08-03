import Testing
@testable import ImageResizer

@Suite("Image Resizer")
struct ImageResizerTests {
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
            format: .jpeg,
            quality: 0.9,
            preserveMetadata: true,
            removeLocation: true,
            backgroundRed: 1,
            backgroundGreen: 1,
            backgroundBlue: 1,
            useCustomDestination: false,
            customDestination: nil
        )
    }

    @Test func landscapeFitsSquare() {
        let result = ResizeMath.fittedSize(source: CGSize(width: 4000, height: 2000), width: 2000, height: 2000)
        #expect(result == CGSize(width: 2000, height: 1000))
    }

    @Test func portraitFitsSquare() {
        let result = ResizeMath.fittedSize(source: CGSize(width: 1000, height: 2000), width: 2000, height: 2000)
        #expect(result == CGSize(width: 1000, height: 2000))
    }

    @Test func smallImageIsNotEnlargedWhenPrevented() {
        let result = ResizeMath.fittedSize(
            source: CGSize(width: 500, height: 250),
            width: 2000,
            height: 2000,
            preventEnlargement: true
        )
        #expect(result == CGSize(width: 500, height: 250))
    }

    @Test func smallImageIsEnlargedWhenAllowed() {
        let result = ResizeMath.fittedSize(
            source: CGSize(width: 500, height: 250),
            width: 2000,
            height: 2000,
            preventEnlargement: false
        )
        #expect(result == CGSize(width: 2000, height: 1000))
    }

    @Test func singleDimensionConstraint() {
        #expect(ResizeMath.fittedSize(source: CGSize(width: 400, height: 200), width: nil, height: 100) == CGSize(width: 200, height: 100))
    }

    @Test func fillModeCropsFromTheCenter() {
        let layout = ResizeMath.layout(
            source: CGSize(width: 4000, height: 2000),
            settings: settings(mode: .fill, width: 1000, height: 1000)
        )
        #expect(layout.outputSize == CGSize(width: 1000, height: 1000))
        #expect(layout.drawRect == CGRect(x: -500, y: 0, width: 2000, height: 1000))
    }

    @Test func longEdgeModePreservesProportions() {
        let layout = ResizeMath.layout(
            source: CGSize(width: 4000, height: 2000),
            settings: settings(mode: .longEdge, longEdge: 1000)
        )
        #expect(layout.outputSize == CGSize(width: 1000, height: 500))
    }

    @Test func percentageModeRespectsNoEnlargement() {
        let layout = ResizeMath.layout(
            source: CGSize(width: 500, height: 250),
            settings: settings(mode: .percentage, percentage: 200, preventEnlargement: true)
        )
        #expect(layout.outputSize == CGSize(width: 500, height: 250))
    }

    @Test func relativePathPreservesFolders() {
        let root = URL(fileURLWithPath: "/Photos")
        let file = URL(fileURLWithPath: "/Photos/Trips/Paris/image.jpg")
        #expect(JobPlanner.relativePath(of: file, beneath: root) == "Trips/Paris/image.jpg")
    }
}
