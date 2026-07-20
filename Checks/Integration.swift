import Foundation
import CoreGraphics
import ImageIO

@main
struct IntegrationChecks {
    static func main() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: manager.currentDirectoryPath)
            .appendingPathComponent(".build-checks/fixture", isDirectory: true)
        try? manager.removeItem(at: root)
        let nested = root.appendingPathComponent("Source/Trips", isDirectory: true)
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)

        let input = nested.appendingPathComponent("landscape.png")
        try makePNG(at: input, width: 640, height: 360, red: 0.1, green: 0.45, blue: 0.9)
        let settings = ResizeSettings(
            width: 320,
            height: 320,
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
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let (jobs, outputs, skipped) = try JobPlanner.plan(sources: [sourceRoot], settings: settings)
        precondition(jobs.count == 1 && skipped == 0)
        precondition(outputs.first?.lastPathComponent == "Source - Resized")
        precondition(jobs[0].destination.path.contains("Source - Resized/Trips/landscape.png"))

        let first = try ResizeEngine.resize(job: jobs[0], settings: settings)
        precondition(first.lastPathComponent == "landscape.jpg")
        try checkDimensions(first, width: 320, height: 180)

        let second = try ResizeEngine.resize(job: jobs[0], settings: settings)
        precondition(second.lastPathComponent == "landscape-2.jpg")
        try checkDimensions(second, width: 320, height: 180)

        var webPSettings = settings
        webPSettings.format = .webp
        let webP = try ResizeEngine.resize(job: jobs[0], settings: webPSettings)
        precondition(webP.pathExtension == "webp")
        try checkDimensions(webP, width: 320, height: 180)
        guard let webPSource = CGImageSourceCreateWithURL(webP as CFURL, nil) else {
            preconditionFailure("WebP output is unreadable")
        }
        precondition(CGImageSourceGetType(webPSource) as String? == "org.webmproject.webp")

        let redInput = nested.appendingPathComponent("red.png")
        try makePNG(at: redInput, width: 640, height: 360, red: 0.9, green: 0.15, blue: 0.1)
        let redWebP = try ResizeEngine.resize(
            job: ResizeJob(source: redInput, destination: outputs[0].appendingPathComponent("Trips/red.png")),
            settings: webPSettings
        )
        let animation = nested.appendingPathComponent("animation.webp")
        try makeAnimatedWebP(frames: [webP, redWebP], durations: [80, 140], output: animation)
        guard let animationSource = CGImageSourceCreateWithURL(animation as CFURL, nil) else {
            preconditionFailure("Animated WebP is unreadable")
        }
        precondition(CGImageSourceGetCount(animationSource) == 2)

        var originalWebPSettings = settings
        originalWebPSettings.format = .original
        let resizedAnimation = try ResizeEngine.resize(
            job: ResizeJob(source: animation, destination: outputs[0].appendingPathComponent("Trips/animation.webp")),
            settings: originalWebPSettings
        )
        guard let resizedAnimationSource = CGImageSourceCreateWithURL(resizedAnimation as CFURL, nil) else {
            preconditionFailure("Resized animated WebP is unreadable")
        }
        precondition(CGImageSourceGetCount(resizedAnimationSource) == 2)
        try checkDimensions(resizedAnimation, width: 320, height: 180)

        let gif = nested.appendingPathComponent("animation.gif")
        try makeAnimatedGIF(frames: [input, redInput], output: gif)
        let resizedGIF = try ResizeEngine.resize(
            job: ResizeJob(source: gif, destination: outputs[0].appendingPathComponent("Trips/animation.gif")),
            settings: originalWebPSettings
        )
        guard let resizedGIFSource = CGImageSourceCreateWithURL(resizedGIF as CFURL, nil) else {
            preconditionFailure("Resized animated GIF is unreadable")
        }
        precondition(CGImageSourceGetCount(resizedGIFSource) == 2)
        try checkDimensions(resizedGIF, width: 320, height: 180)
        print("Image round-trip, collision, WebP, animated WebP, and animated GIF checks passed.")
    }

    static func makePNG(at url: URL, width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
    }

    static func checkDimensions(_ url: URL, width: Int, height: Int) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == width,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == height else {
            throw NSError(domain: "ImageResizerChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected output dimensions"])
        }
    }

    static func makeAnimatedWebP(frames: [URL], durations: [Int], output: URL) throws {
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Vendor/WebPTools/img2webp")
        let process = Process()
        process.executableURL = executable
        var arguments = ["-loop", "3"]
        for (frame, duration) in zip(frames, durations) {
            arguments += ["-d", String(duration), frame.path]
        }
        arguments += ["-o", output.path]
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
    }

    static func makeAnimatedGIF(frames: [URL], output: URL) throws {
        let images = frames.compactMap { url -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        precondition(images.count == frames.count)
        let destination = CGImageDestinationCreateWithURL(output as CFURL, "com.compuserve.gif" as CFString, images.count, nil)!
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 2]
        ] as CFDictionary)
        for image in images {
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]
            ] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(destination))
    }
}
