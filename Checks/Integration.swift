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

        if let rawFixture = ProcessInfo.processInfo.environment["IMAGE_RESIZER_RAW_FIXTURE"], !rawFixture.isEmpty {
            var rawSettings = settings
            rawSettings.width = 800
            rawSettings.height = 1200
            rawSettings.format = .original
            let rawInput = URL(fileURLWithPath: rawFixture)
            let rawOutput = try ResizeEngine.resize(
                job: ResizeJob(source: rawInput, destination: outputs[0].appendingPathComponent(rawInput.lastPathComponent)),
                settings: rawSettings
            )
            try checkDimensions(rawOutput, width: 800, height: 1199)
            try checkImageIsNotBlack(rawOutput)
            precondition(rawOutput.pathExtension == "jpg")

            var rawWebPSettings = rawSettings
            rawWebPSettings.format = .webp
            let rawWebPOutput = try ResizeEngine.resize(
                job: ResizeJob(source: rawInput, destination: outputs[0].appendingPathComponent(rawInput.lastPathComponent)),
                settings: rawWebPSettings
            )
            try checkDimensions(rawWebPOutput, width: 800, height: 1199)
            try checkImageIsNotBlack(rawWebPOutput)
            precondition(rawWebPOutput.pathExtension == "webp")
            print("Optional camera RAW fixture check passed.")
        }

        print("Image round-trip, collision, WebP, animated WebP, animated GIF, and RAW-path checks passed.")
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

    static func checkImageIsNotBlack(_ url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "ImageResizerChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Output image is unreadable"])
        }
        let width = 32
        let height = 32
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else {
            throw NSError(domain: "ImageResizerChecks", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not sample output image"])
        }
        let values = [UInt8](pixels)
        var colorTotal = 0
        for offset in stride(from: 0, to: values.count, by: 4) {
            colorTotal += Int(values[offset]) + Int(values[offset + 1]) + Int(values[offset + 2])
        }
        precondition(colorTotal > width * height * 3 * 5, "Output image is effectively black")
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
