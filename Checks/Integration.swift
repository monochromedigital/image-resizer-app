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
            mode: .fit,
            width: 320,
            height: 320,
            longEdge: nil,
            percentage: nil,
            preventEnlargement: true,
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
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let (jobs, outputs, skipped) = try JobPlanner.plan(sources: [sourceRoot], settings: settings)
        precondition(jobs.count == 1 && skipped == 0)
        precondition(outputs.first?.lastPathComponent == "Source - Resized")
        // The planner resolves the whole path up front: source folder structure, the
        // suffix, and the JPEG extension the settings imply.
        precondition(jobs[0].output.path.contains("Source - Resized/Trips/landscape-resized.jpg"))

        let first = try ResizeEngine.resize(job: jobs[0])
        precondition(first.lastPathComponent == "landscape-resized.jpg")
        try checkDimensions(first, width: 320, height: 180)

        // Replanning the same source now that the first output exists must step around
        // it. Collision resolution moved to plan time, so this is a planner assertion.
        let (replanned, _, _) = try JobPlanner.plan(sources: [sourceRoot], settings: settings)
        precondition(replanned[0].output.lastPathComponent == "landscape-resized-2.jpg")
        let second = try ResizeEngine.resize(job: replanned[0])
        precondition(second.lastPathComponent == "landscape-resized-2.jpg")
        try checkDimensions(second, width: 320, height: 180)

        // Two sources that slug to the same stem inside one batch must not collide with
        // each other either — this is the case the old filesystem probe could not see,
        // because neither file exists when the names are chosen.
        let collisionRoot = root.appendingPathComponent("Collide", isDirectory: true)
        try manager.createDirectory(at: collisionRoot, withIntermediateDirectories: true)
        try makePNG(at: collisionRoot.appendingPathComponent("IMG_1234 Red Chair.png"), width: 40, height: 40, red: 0.4, green: 0.2, blue: 0.6)
        try makePNG(at: collisionRoot.appendingPathComponent("img-1234-red-chair.png"), width: 40, height: 40, red: 0.6, green: 0.2, blue: 0.4)
        var sluggedSettings = settings
        sluggedSettings.filenameSuffix = ""
        sluggedSettings.webExport = WebExport(isEnabled: true, naming: Naming())
        let (sluggedJobs, _, _) = try JobPlanner.plan(sources: [collisionRoot], settings: sluggedSettings)
        precondition(sluggedJobs.count == 2)
        let sluggedNames = Set(sluggedJobs.map(\.output.lastPathComponent))
        precondition(sluggedNames == ["1234-red-chair.jpg", "1234-red-chair-2.jpg"], "slugged names collided")
        for job in sluggedJobs { _ = try ResizeEngine.resize(job: job) }

        // One source fanned out across a ladder in a single plan. The 1600 rung is wider
        // than the 640px source and must be dropped rather than clamped, and each file is
        // named after the size it is actually written at.
        let ladderRoot = root.appendingPathComponent("Ladder", isDirectory: true)
        try manager.createDirectory(at: ladderRoot, withIntermediateDirectories: true)
        try makePNG(at: ladderRoot.appendingPathComponent("Wide Banner.png"), width: 640, height: 360, red: 0.2, green: 0.5, blue: 0.8)
        var ladderSettings = settings
        ladderSettings.filenameSuffix = ""
        ladderSettings.width = nil
        ladderSettings.height = nil
        ladderSettings.webExport = WebExport(
            isEnabled: true,
            naming: Naming(template: "{slug}-{width}"),
            ladder: Ladder(widths: [200, 400, 1_600], includeOriginalSize: true)
        )
        let (ladderJobs, _, _) = try JobPlanner.plan(sources: [ladderRoot], settings: ladderSettings)
        precondition(ladderJobs.count == 3, "expected three rungs, got \(ladderJobs.count)")
        precondition(
            ladderJobs.map(\.output.lastPathComponent) == ["wide-banner-200.jpg", "wide-banner-400.jpg", "wide-banner-640.jpg"],
            "unexpected ladder filenames: \(ladderJobs.map(\.output.lastPathComponent))"
        )
        for job in ladderJobs { _ = try ResizeEngine.resize(job: job) }
        try checkDimensions(ladderJobs[0].output, width: 200, height: 113)
        try checkDimensions(ladderJobs[1].output, width: 400, height: 225)
        try checkDimensions(ladderJobs[2].output, width: 640, height: 360)

        let smallInput = nested.appendingPathComponent("small.png")
        try makePNG(at: smallInput, width: 80, height: 40, red: 0.25, green: 0.7, blue: 0.35)
        let smallJob = ResizeJob(source: smallInput, output: outputs[0].appendingPathComponent("Trips/small-resized.jpg"), settings: settings)
        let protected = try ResizeEngine.resize(job: smallJob)
        precondition(protected.lastPathComponent == "small-resized.jpg")
        try checkDimensions(protected, width: 80, height: 40)

        var blankSuffixSettings = settings
        blankSuffixSettings.filenameSuffix = ""
        let blankSuffix = try ResizeEngine.resize(
            job: ResizeJob(source: smallInput, output: outputs[0].appendingPathComponent("Trips/blank.jpg"), settings: blankSuffixSettings)
        )
        precondition(blankSuffix.lastPathComponent == "blank.jpg")
        try checkDimensions(blankSuffix, width: 80, height: 40)

        var enlargementSettings = settings
        enlargementSettings.preventEnlargement = false
        let enlarged = try ResizeEngine.resize(job: ResizeJob(source: smallJob.source, output: smallJob.output, settings: enlargementSettings))
        try checkDimensions(enlarged, width: 320, height: 160)

        var fillSettings = settings
        fillSettings.mode = .fill
        let filled = try ResizeEngine.resize(
            job: ResizeJob(source: input, output: outputs[0].appendingPathComponent("Trips/fill.jpg"), settings: fillSettings)
        )
        try checkDimensions(filled, width: 320, height: 320)

        var longEdgeSettings = settings
        longEdgeSettings.mode = .longEdge
        longEdgeSettings.longEdge = 200
        let longEdge = try ResizeEngine.resize(
            job: ResizeJob(source: input, output: outputs[0].appendingPathComponent("Trips/long-edge.jpg"), settings: longEdgeSettings)
        )
        try checkDimensions(longEdge, width: 200, height: 113)

        var percentageSettings = settings
        percentageSettings.mode = .percentage
        percentageSettings.percentage = 50
        let percentage = try ResizeEngine.resize(
            job: ResizeJob(source: input, output: outputs[0].appendingPathComponent("Trips/percentage.jpg"), settings: percentageSettings)
        )
        try checkDimensions(percentage, width: 320, height: 180)

        let detailInput = nested.appendingPathComponent("detail.png")
        try makeDetailedPNG(at: detailInput, width: 1_000, height: 750)
        var detailSettings = settings
        detailSettings.width = 800
        detailSettings.height = 800
        detailSettings.quality = 0.95
        let baselineJPEG = try ResizeEngine.resize(
            job: ResizeJob(source: detailInput, output: outputs[0].appendingPathComponent("Trips/detail-baseline.jpg"), settings: detailSettings)
        )
        let baselineJPEGBytes = try Data(contentsOf: baselineJPEG).count
        var targetJPEGSettings = detailSettings
        targetJPEGSettings.targetFileSizeEnabled = true
        targetJPEGSettings.targetFileSizeBytes = baselineJPEGBytes / 2
        let targetJPEG = try ResizeEngine.resize(
            job: ResizeJob(source: detailInput, output: outputs[0].appendingPathComponent("Trips/detail-target.jpg"), settings: targetJPEGSettings)
        )
        let targetJPEGBytes = try Data(contentsOf: targetJPEG).count
        precondition(targetJPEGBytes <= baselineJPEGBytes / 2)
        precondition(targetJPEGBytes < baselineJPEGBytes)
        try checkDimensions(targetJPEG, width: 800, height: 600)

        var impossibleSettings = detailSettings
        impossibleSettings.targetFileSizeEnabled = true
        impossibleSettings.targetFileSizeBytes = 1
        do {
            _ = try ResizeEngine.resize(
                job: ResizeJob(source: detailInput, output: outputs[0].appendingPathComponent("Trips/detail-impossible.jpg"), settings: impossibleSettings)
            )
            preconditionFailure("An impossible file-size limit should fail")
        } catch ResizeEngineError.targetFileSizeTooSmall(let bytes) {
            precondition(bytes == 1)
        }

        // Replanned rather than reusing jobs[0]: a job's output extension is fixed by the
        // settings it was planned with, so it cannot be reused under a different format.
        var webPSettings = settings
        webPSettings.format = .webp
        let (webPJobs, _, _) = try JobPlanner.plan(sources: [input], settings: webPSettings)
        precondition(webPJobs.count == 1)
        precondition(webPJobs[0].output.lastPathComponent == "landscape-resized.webp")
        let webP = try ResizeEngine.resize(job: webPJobs[0])
        precondition(webP.lastPathComponent == "landscape-resized.webp")
        try checkDimensions(webP, width: 320, height: 180)
        guard let webPSource = CGImageSourceCreateWithURL(webP as CFURL, nil) else {
            preconditionFailure("WebP output is unreadable")
        }
        precondition(CGImageSourceGetType(webPSource) as String? == "org.webmproject.webp")

        var detailWebPSettings = detailSettings
        detailWebPSettings.format = .webp
        let baselineWebP = try ResizeEngine.resize(
            job: ResizeJob(source: detailInput, output: outputs[0].appendingPathComponent("Trips/detail-webp-baseline.webp"), settings: detailWebPSettings)
        )
        let baselineWebPBytes = try Data(contentsOf: baselineWebP).count
        detailWebPSettings.targetFileSizeEnabled = true
        detailWebPSettings.targetFileSizeBytes = baselineWebPBytes / 2
        let targetWebP = try ResizeEngine.resize(
            job: ResizeJob(source: detailInput, output: outputs[0].appendingPathComponent("Trips/detail-webp-target.webp"), settings: detailWebPSettings)
        )
        let targetWebPBytes = try Data(contentsOf: targetWebP).count
        precondition(targetWebPBytes <= baselineWebPBytes / 2)
        precondition(targetWebPBytes < baselineWebPBytes)
        try checkDimensions(targetWebP, width: 800, height: 600)

        let redInput = nested.appendingPathComponent("red.png")
        try makePNG(at: redInput, width: 640, height: 360, red: 0.9, green: 0.15, blue: 0.1)
        let redWebP = try ResizeEngine.resize(
            job: ResizeJob(source: redInput, output: outputs[0].appendingPathComponent("Trips/red.webp"), settings: webPSettings)
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
            job: ResizeJob(source: animation, output: outputs[0].appendingPathComponent("Trips/animation-resized.webp"), settings: originalWebPSettings)
        )
        guard let resizedAnimationSource = CGImageSourceCreateWithURL(resizedAnimation as CFURL, nil) else {
            preconditionFailure("Resized animated WebP is unreadable")
        }
        precondition(CGImageSourceGetCount(resizedAnimationSource) == 2)
        try checkDimensions(resizedAnimation, width: 320, height: 180)

        let gif = nested.appendingPathComponent("animation.gif")
        try makeAnimatedGIF(frames: [input, redInput], output: gif)
        let resizedGIF = try ResizeEngine.resize(
            job: ResizeJob(source: gif, output: outputs[0].appendingPathComponent("Trips/animation-resized.gif"), settings: originalWebPSettings)
        )
        guard let resizedGIFSource = CGImageSourceCreateWithURL(resizedGIF as CFURL, nil) else {
            preconditionFailure("Resized animated GIF is unreadable")
        }
        precondition(CGImageSourceGetCount(resizedGIFSource) == 2)
        try checkDimensions(resizedGIF, width: 320, height: 180)

        // Guarded on the same runtime probe the format picker uses, so this check tracks
        // whatever the build machine can actually write instead of assuming a version.
        if OutputFormat.writable.contains(.avif) {
            var avifSettings = settings
            avifSettings.format = .avif
            let (avifJobs, _, _) = try JobPlanner.plan(sources: [input], settings: avifSettings)
            precondition(avifJobs[0].output.lastPathComponent == "landscape-resized.avif")
            let avif = try ResizeEngine.resize(job: avifJobs[0])
            try checkDimensions(avif, width: 320, height: 180)
            guard let avifSource = CGImageSourceCreateWithURL(avif as CFURL, nil) else {
                preconditionFailure("AVIF output is unreadable")
            }
            precondition(CGImageSourceGetType(avifSource) as String? == "public.avif")

            // AVIF has to honour the quality slider; it previously applied only to JPEG
            // and HEIC, so a regression here would silently ignore the setting.
            var lowQuality = detailSettings
            lowQuality.format = .avif
            lowQuality.quality = 0.1
            var highQuality = lowQuality
            highQuality.quality = 0.9
            let lowBytes = try Data(contentsOf: ResizeEngine.resize(
                job: ResizeJob(source: detailInput, output: outputs[0].appendingPathComponent("Trips/q-low.avif"), settings: lowQuality)
            )).count
            let highBytes = try Data(contentsOf: ResizeEngine.resize(
                job: ResizeJob(source: detailInput, output: outputs[0].appendingPathComponent("Trips/q-high.avif"), settings: highQuality)
            )).count
            precondition(lowBytes < highBytes, "AVIF ignored the quality setting: \(lowBytes) vs \(highBytes)")
            print("AVIF round-trip and quality checks passed.")
        } else {
            print("AVIF is not writable on this machine; skipped its round-trip check.")
        }

        let transparentInput = nested.appendingPathComponent("transparent.png")
        try makeTransparentPNG(at: transparentInput, width: 400, height: 300)

        // Target file size now bisects any lossy type, not only JPEG. HEIC is included
        // because it was always lossy and always excluded — a pre-existing gap.
        for lossy in [OutputFormat.heic, .avif] where OutputFormat.writable.contains(lossy) {
            let suffix = lossy.preferredExtension!
            var baselineSettings = detailSettings
            baselineSettings.format = lossy
            let baseline = try ResizeEngine.resize(job: ResizeJob(
                source: detailInput,
                output: outputs[0].appendingPathComponent("Trips/target-\(suffix)-baseline.\(suffix)"),
                settings: baselineSettings
            ))
            let baselineBytes = try Data(contentsOf: baseline).count

            var targetSettings = baselineSettings
            targetSettings.targetFileSizeEnabled = true
            targetSettings.targetFileSizeBytes = baselineBytes / 2
            let target = try ResizeEngine.resize(job: ResizeJob(
                source: detailInput,
                output: outputs[0].appendingPathComponent("Trips/target-\(suffix).\(suffix)"),
                settings: targetSettings
            ))
            let targetBytes = try Data(contentsOf: target).count
            precondition(
                targetBytes <= baselineBytes / 2,
                "\(lossy.rawValue) overshot its limit: \(targetBytes) > \(baselineBytes / 2)"
            )
            try checkDimensions(target, width: 800, height: 600)

            // A limit nothing can meet must still fail loudly rather than writing an
            // oversized file and reporting success.
            var impossible = targetSettings
            impossible.targetFileSizeBytes = 1
            do {
                _ = try ResizeEngine.resize(job: ResizeJob(
                    source: detailInput,
                    output: outputs[0].appendingPathComponent("Trips/target-\(suffix)-impossible.\(suffix)"),
                    settings: impossible
                ))
                preconditionFailure("\(lossy.rawValue) accepted an impossible file-size limit")
            } catch ResizeEngineError.targetFileSizeTooSmall {}

            // The bisection renders through its own path, so it has to be told the real
            // output type: `render` decides whether to keep an alpha channel from it, and
            // JPEG would flatten transparency that AVIF and HEIC both support.
            var alphaSettings = targetSettings
            alphaSettings.targetFileSizeBytes = 400_000
            let alphaOut = try ResizeEngine.resize(job: ResizeJob(
                source: transparentInput,
                output: outputs[0].appendingPathComponent("Trips/alpha-\(suffix).\(suffix)"),
                settings: alphaSettings
            ))
            let keptAlpha = try hasAlpha(alphaOut)
            precondition(keptAlpha, "\(lossy.rawValue) target-size path dropped the alpha channel")
            print("\(lossy.rawValue) target file size checks passed.")
        }



        // Colour tagging. Frames are always composited into an sRGB context, so a source
        // profile describes colours the output no longer contains. Copying it made a
        // Display P3 source come back as sRGB pixels wearing a P3 tag, which browsers
        // then re-expand into visibly wrong colours.
        let p3Profile = CGColorSpace(name: CGColorSpace.displayP3)!.copyICCData()! as Data
        let sRGBProfile = CGColorSpace(name: CGColorSpace.sRGB)!.copyICCData()! as Data
        let p3ProfileURL = root.appendingPathComponent("p3.icc")
        try p3Profile.write(to: p3ProfileURL)

        var plainWebPSettings = settings
        plainWebPSettings.format = .webp
        let plainWebP = try ResizeEngine.resize(job: ResizeJob(
            source: input,
            output: outputs[0].appendingPathComponent("Trips/colour-source.webp"),
            settings: plainWebPSettings
        ))
        let taggedSource = root.appendingPathComponent("p3-source.webp")
        precondition(
            webpmux(["-set", "icc", p3ProfileURL.path, plainWebP.path, "-o", taggedSource.path]),
            "could not build a P3-tagged WebP fixture"
        )
        precondition(iccData(of: taggedSource, scratch: root) == p3Profile, "fixture lost its P3 tag")

        // Default: the stale profile must not survive. Untagged is correct — every
        // browser reads untagged WebP as sRGB.
        let untagged = try ResizeEngine.resize(job: ResizeJob(
            source: taggedSource,
            output: outputs[0].appendingPathComponent("Trips/colour-untagged.webp"),
            settings: plainWebPSettings
        ))
        precondition(
            iccData(of: untagged, scratch: root) != p3Profile,
            "resized WebP kept the source Display P3 profile over sRGB pixels"
        )

        // Opting in writes an explicit sRGB profile instead.
        var taggedSettings = plainWebPSettings
        taggedSettings.webExport = WebExport(isEnabled: true, color: ColorPolicy(embedProfile: .sRGB))
        let tagged = try ResizeEngine.resize(job: ResizeJob(
            source: taggedSource,
            output: outputs[0].appendingPathComponent("Trips/colour-srgb.webp"),
            settings: taggedSettings
        ))
        precondition(iccData(of: tagged, scratch: root) == sRGBProfile, "explicit sRGB profile was not embedded")
        print("Colour profile checks passed.")

        if let rawFixture = ProcessInfo.processInfo.environment["IMAGE_RESIZER_RAW_FIXTURE"], !rawFixture.isEmpty {
            var rawSettings = settings
            rawSettings.width = 800
            rawSettings.height = 1200
            rawSettings.format = .original
            let rawInput = URL(fileURLWithPath: rawFixture)
            // Planned rather than hand-built, so this exercises the planner recognising
            // an unwritable source type and resolving the extension to jpg before any
            // decoding happens. Custom destination keeps output inside the fixture tree.
            rawSettings.useCustomDestination = true
            rawSettings.customDestination = root
            let (rawJobs, _, _) = try JobPlanner.plan(sources: [rawInput], settings: rawSettings)
            precondition(rawJobs.count == 1)
            precondition(rawJobs[0].output.lastPathComponent == "\(rawInput.deletingPathExtension().lastPathComponent)-resized.jpg")
            let rawOutput = try ResizeEngine.resize(job: rawJobs[0])
            try checkDimensions(rawOutput, width: 800, height: 1199)
            try checkImageIsNotBlack(rawOutput)

            var rawTargetSettings = rawSettings
            rawTargetSettings.targetFileSizeEnabled = true
            rawTargetSettings.targetFileSizeBytes = try Data(contentsOf: rawOutput).count
            let rawTargetOutput = try ResizeEngine.resize(
                job: ResizeJob(source: rawInput, output: outputs[0].appendingPathComponent("raw-target.jpg"), settings: rawTargetSettings)
            )
            let rawTargetBytes = try Data(contentsOf: rawTargetOutput).count
            precondition(rawTargetBytes <= rawTargetSettings.targetFileSizeBytes!)
            try checkDimensions(rawTargetOutput, width: 800, height: 1199)
            try checkImageIsNotBlack(rawTargetOutput)

            var rawFillSettings = rawSettings
            rawFillSettings.mode = .fill
            rawFillSettings.width = 800
            rawFillSettings.height = 800
            let rawFillOutput = try ResizeEngine.resize(
                job: ResizeJob(source: rawInput, output: outputs[0].appendingPathComponent("raw-fill.jpg"), settings: rawFillSettings)
            )
            try checkDimensions(rawFillOutput, width: 800, height: 800)
            try checkImageIsNotBlack(rawFillOutput)

            var rawWebPSettings = rawSettings
            rawWebPSettings.format = .webp
            let (rawWebPJobs, _, _) = try JobPlanner.plan(sources: [rawInput], settings: rawWebPSettings)
            precondition(rawWebPJobs[0].output.lastPathComponent == "\(rawInput.deletingPathExtension().lastPathComponent)-resized.webp")
            let rawWebPOutput = try ResizeEngine.resize(job: rawWebPJobs[0])
            try checkDimensions(rawWebPOutput, width: 800, height: 1199)
            try checkImageIsNotBlack(rawWebPOutput)
            print("Optional camera RAW fixture check passed.")
        }

        print("Image round-trip, target file size, filename suffix, resize modes, no-enlargement, collision, WebP, animated WebP, animated GIF, and RAW-path checks passed.")
    }

    /// Runs the bundled webpmux and reports whether the chunk existed.
    @discardableResult
    static func webpmux(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Vendor/WebPTools/webpmux")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func iccData(of webp: URL, scratch: URL) -> Data? {
        let extracted = scratch.appendingPathComponent("probe-\(UUID().uuidString).icc")
        guard webpmux(["-get", "icc", webp.path, "-o", extracted.path]) else { return nil }
        return try? Data(contentsOf: extracted)
    }

    static func makeTransparentPNG(at url: URL, width: Int, height: Int) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
    }

    static func hasAlpha(_ url: URL) throws -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw NSError(domain: "ImageResizerChecks", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unreadable output"])
        }
        return (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false
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

    static func makeDetailedPNG(at url: URL, width: Int, height: Int) throws {
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let values = buffer.bindMemory(to: UInt8.self)
            var state: UInt64 = 0xC0FFEE
            for pixel in 0..<(width * height) {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                let offset = pixel * 4
                values[offset] = UInt8(truncatingIfNeeded: state >> 16)
                values[offset + 1] = UInt8(truncatingIfNeeded: state >> 24)
                values[offset + 2] = UInt8(truncatingIfNeeded: state >> 32)
                values[offset + 3] = 255
            }
        }
        let provider = CGDataProvider(data: pixels as CFData)!
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
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
