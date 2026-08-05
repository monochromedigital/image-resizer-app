import Foundation
import CoreGraphics
import ImageIO

@main
struct IntegrationChecks {
    static func main() async throws {
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
        precondition(sluggedNames == ["red-chair.jpg", "red-chair-2.jpg"], "slugged names collided: \(sluggedNames.sorted())")
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


        // Rights metadata is the only place the app authors metadata rather than copying
        // it, and XMP needs a different destination call than everything else — so this
        // reads every field back out of a real file rather than trusting the write.
        let rights = RightsMetadata(
            creator: "Monochrome Digital",
            copyrightNotice: "© 2026 Monochrome Digital",
            credit: "Photo: Monochrome Digital",
            webStatementURL: "https://monochrome.digital/licence",
            licensorURL: "https://monochrome.digital/licence-this",
            titlePolicy: .fromFilename,
            descriptionPolicy: .keepExisting
        )
        var rightsSettings = settings
        rightsSettings.webExport = WebExport(isEnabled: true, rights: rights)
        let rightsOut = try ResizeEngine.resize(job: ResizeJob(
            source: input,
            output: outputs[0].appendingPathComponent("Trips/rights.jpg"),
            settings: rightsSettings
        ))
        guard let rightsSource = CGImageSourceCreateWithURL(rightsOut as CFURL, nil),
              let rightsProperties = CGImageSourceCopyPropertiesAtIndex(rightsSource, 0, nil) as? [CFString: Any],
              let iptc = rightsProperties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] else {
            preconditionFailure("rights output carries no IPTC")
        }
        precondition((iptc[kCGImagePropertyIPTCByline] as? [String]) == ["Monochrome Digital"], "byline")
        precondition((iptc[kCGImagePropertyIPTCCopyrightNotice] as? String) == "© 2026 Monochrome Digital", "copyright")
        precondition((iptc[kCGImagePropertyIPTCCredit] as? String) == "Photo: Monochrome Digital", "credit")
        // landscape.png, slugged and humanised.
        precondition((iptc[kCGImagePropertyIPTCObjectName] as? String) == "Landscape", "title from filename")

        var xmp: [String: String] = [:]
        if let metadata = CGImageSourceCopyMetadataAtIndex(rightsSource, 0, nil) {
            CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
                if let value = CGImageMetadataTagCopyValue(tag) as? String { xmp[path as String] = value }
                return true
            }
        }
        precondition(xmp["xmpRights:WebStatement"] == "https://monochrome.digital/licence", "web statement: \(xmp)")
        precondition(xmp["plus:Licensor[0].LicensorURL"] == "https://monochrome.digital/licence-this", "licensor: \(xmp)")
        // ImageIO mirrors IPTC into XMP on its own, so dc:creator arrives without being set.
        precondition(xmp["dc:creator[0]"] == "Monochrome Digital", "creator mirrored into XMP")

        // The same fields have to survive the target-size path, which pre-renders frames
        // and encodes into memory rather than straight to the destination.
        var rightsTargetSettings = detailSettings
        rightsTargetSettings.webExport = rightsSettings.webExport
        rightsTargetSettings.targetFileSizeEnabled = true
        rightsTargetSettings.targetFileSizeBytes = 200_000
        let rightsTarget = try ResizeEngine.resize(job: ResizeJob(
            source: detailInput,
            output: outputs[0].appendingPathComponent("Trips/rights-target.jpg"),
            settings: rightsTargetSettings
        ))
        guard let targetSource = CGImageSourceCreateWithURL(rightsTarget as CFURL, nil),
              let targetProperties = CGImageSourceCopyPropertiesAtIndex(targetSource, 0, nil) as? [CFString: Any],
              let targetIPTC = targetProperties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] else {
            preconditionFailure("target-size rights output carries no IPTC")
        }
        precondition((targetIPTC[kCGImagePropertyIPTCCredit] as? String) == "Photo: Monochrome Digital", "credit survives bisection")
        // Derived from the source, not the output — the output name carries a ladder width.
        precondition((targetIPTC[kCGImagePropertyIPTCObjectName] as? String) == "Detail", "title comes from the source filename")
        print("Rights metadata checks passed.")


        // Smart cropping, end to end. A 1000×500 source cropped to a 500×500 square keeps
        // the middle and throws both ends away, so a subject at the left edge is exactly
        // what a centre crop loses — and what the focus point has to bring back.
        let cropRoot = root.appendingPathComponent("Crop", isDirectory: true)
        try manager.createDirectory(at: cropRoot, withIntermediateDirectories: true)
        let cropSource = cropRoot.appendingPathComponent("subject.png")
        try makeMarkedPNG(
            at: cropSource, width: 1_000, height: 500,
            marker: CGRect(x: 0, y: 200, width: 100, height: 100)
        )
        var cropSettings = settings
        cropSettings.mode = .fill
        cropSettings.width = 500
        cropSettings.height = 500
        cropSettings.format = .png

        let centred = try ResizeEngine.resize(job: ResizeJob(
            source: cropSource,
            output: cropRoot.appendingPathComponent("centred.png"),
            settings: cropSettings
        ))
        var focusedSettings = cropSettings
        focusedSettings.focus = CGPoint(x: 0.05, y: 0.5)
        let focused = try ResizeEngine.resize(job: ResizeJob(
            source: cropSource,
            output: cropRoot.appendingPathComponent("focused.png"),
            settings: focusedSettings
        ))

        // The marker sits at x 0–100 of the source. A centre crop starts at x 250, so it
        // cannot contain it; anchored on the subject, the crop starts at x 0 and does.
        guard let centredPixel = samplePixel(centred, x: 50, fromBottom: 250),
              let focusedPixel = samplePixel(focused, x: 50, fromBottom: 250) else {
            preconditionFailure("could not sample the crops")
        }
        precondition(centredPixel.red < 100, "the centre crop should have missed the subject: \(centredPixel)")
        precondition(
            focusedPixel.red > 200 && focusedPixel.green < 100,
            "the anchored crop should contain the subject: \(focusedPixel)"
        )
        print("Smart crop checks passed.")

        // Sidecars end to end: a real laddered batch, then the manifest and markup read
        // back off disk. This is what plan-time naming was for — the manifest describes
        // files by the names they were actually written under.
        let sidecarRoot = root.appendingPathComponent("Sidecars", isDirectory: true)
        try manager.createDirectory(at: sidecarRoot, withIntermediateDirectories: true)
        try makePNG(at: sidecarRoot.appendingPathComponent("IMG_4821 Café Sign.png"), width: 1_000, height: 562, red: 0.8, green: 0.4, blue: 0.2)
        var sidecarSettings = settings
        sidecarSettings.filenameSuffix = ""
        sidecarSettings.width = nil
        sidecarSettings.height = nil
        sidecarSettings.webExport = WebExport(
            isEnabled: true,
            naming: Naming(template: "{slug}-{width}"),
            ladder: Ladder(widths: [400, 800]),
            // WebP rather than AVIF, because this has to fan out on every machine the
            // checks run on and only macOS 26 can write AVIF. It also exercises the
            // subprocess encoder, which is the path a matrix is most likely to break.
            formats: FormatPlan(alternatives: [FormatPlan.Entry(format: .webp)]),
            social: SocialImage(),
            rights: RightsMetadata(titlePolicy: .fromFilename),
            sidecars: Sidecars(placeholder: .base64DataURI, pathPrefix: "/images")
        )
        let (sidecarJobs, sidecarOutputs, sidecarSkipped) = try JobPlanner.plan(sources: [sidecarRoot], settings: sidecarSettings)
        precondition(
            sidecarJobs.count == 5,
            "expected two rungs in two formats plus a share image, got \(sidecarJobs.count)"
        )
        // Names are resolved at plan time, and a format is part of what makes one unique —
        // two rungs colliding into one name would show up here as a `-2` suffix. The share
        // image carries a marker rather than a width for the same reason.
        precondition(
            Set(sidecarJobs.map(\.output.lastPathComponent)) == [
                "cafe-sign-400.jpg", "cafe-sign-800.jpg",
                "cafe-sign-400.webp", "cafe-sign-800.webp",
                "cafe-sign-social.jpg"
            ],
            "planned names: \(sidecarJobs.map(\.output.lastPathComponent))"
        )
        precondition(
            sidecarJobs.filter { $0.role == .social }.count == 1,
            "exactly one share image per source"
        )
        // Through the real batch loop, so the engine's own rendition recording — the
        // dimensions and byte counts the manifest is built from — is what gets checked.
        let batch = await ResizeEngine.process(
            jobs: sidecarJobs,
            skipped: sidecarSkipped,
            control: ProcessingControl()
        ) { _ in }
        precondition(batch.progress.failed == 0, "sidecar batch failed: \(batch.errors)")
        precondition(batch.renditions.count == 5, "the batch recorded \(batch.renditions.count) renditions")
        // The role has to survive the engine, or the share image rejoins the ladder in
        // every sidecar downstream.
        guard let recordedShare = batch.renditions.first(where: { $0.role == .social }) else {
            preconditionFailure("the engine did not record the share image as one")
        }
        // Fill crops to the requested shape, and preventEnlargement scales the whole thing
        // down rather than upscaling a 1000px source to 1200 — the ratio is what matters.
        precondition(
            recordedShare.width == 1_000 && recordedShare.height == 525,
            "share crop: \(recordedShare.width)×\(recordedShare.height)"
        )
        precondition(batch.renditions.allSatisfy { $0.bytes > 0 }, "renditions must record real byte counts")
        precondition(batch.renditions.contains { $0.width == 400 }, "the 400 rung was recorded")
        let sidecarFiles = try SidecarWriter.write(
            renditions: batch.renditions,
            outputDirectories: sidecarOutputs,
            settings: sidecarSettings
        )
        precondition(sidecarFiles.count == 2, "expected a manifest and a snippet, got \(sidecarFiles.count)")

        let manifestURL = sidecarOutputs[0].appendingPathComponent("manifest.json")
        let manifest = try JSONSerialization.jsonObject(with: try Data(contentsOf: manifestURL)) as? [String: Any] ?? [:]
        guard let images = manifest["images"] as? [[String: Any]], let first = images.first,
              let manifestRenditions = first["renditions"] as? [[String: Any]] else {
            preconditionFailure("manifest has no images")
        }
        precondition((first["slug"] as? String) == "cafe-sign", "manifest slug: \(String(describing: first["slug"]))")
        precondition((first["source"] as? String) == "IMG_4821 Café Sign.png", "manifest names the source")
        precondition(manifestRenditions.count == 4, "manifest lists every rendition")
        // Grouped by format, the alternative first, each group ascending by width — the
        // order the markup offers them in.
        precondition(
            manifestRenditions.compactMap { $0["path"] as? String } == [
                "/images/cafe-sign-400.webp", "/images/cafe-sign-800.webp",
                "/images/cafe-sign-400.jpg", "/images/cafe-sign-800.jpg"
            ],
            "manifest paths: \(manifestRenditions.compactMap { $0["path"] as? String })"
        )
        precondition((manifestRenditions[0]["width"] as? Int) == 400, "manifest width")
        precondition((manifestRenditions[0]["format"] as? String) == "webp", "manifest names each format")
        precondition((manifestRenditions[0]["bytes"] as? Int ?? 0) > 0, "manifest records real byte counts")
        precondition((first["placeholder"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true, "placeholder is an inline data URI")

        let snippet = try String(contentsOf: sidecarOutputs[0].appendingPathComponent("snippet.html"), encoding: .utf8)
        precondition(snippet.contains("srcset=\"/images/cafe-sign-400.jpg 400w, /images/cafe-sign-800.jpg 800w\""), "snippet srcset: \(snippet)")
        precondition(snippet.contains("alt=\"Cafe Sign\""), "snippet alt")
        // Proves the writer threads the hero through, not just that the markup can express
        // it: the first image of a run is the one written with priority.
        precondition(snippet.contains("fetchpriority=\"high\""), "the written snippet prioritises the first image")
        // The structured-data block is opt-in on rights having something to say, and this
        // batch's rights are a title policy alone.
        precondition(snippet.contains("application/ld+json"), "the written snippet carries structured data")
        precondition(snippet.contains("\"@type\" : \"ImageObject\""), "structured data types the image: \(snippet)")
        // The whole point of the matrix: real files in both formats, offered as a choice.
        precondition(snippet.contains("<picture>"), "the written snippet wraps the alternatives")
        precondition(snippet.contains("<source type=\"image/webp\""), "the alternative is offered by type")
        precondition(
            snippet.contains("srcset=\"/images/cafe-sign-400.webp 400w, /images/cafe-sign-800.webp 800w\""),
            "the source carries its own ladder: \(snippet)"
        )
        precondition(
            snippet.contains("<meta property=\"og:image\" content=\"/images/cafe-sign-social.jpg\">"),
            "the snippet carries the link preview: \(snippet)"
        )
        precondition(snippet.contains("summary_large_image"), "the card is the large one")
        // The whole reason the role exists: a crop must not be offered as a size.
        precondition(
            !snippet.contains("cafe-sign-social.jpg 1000w"),
            "the share image reached a srcset: \(snippet)"
        )
        precondition(
            (first["social"] as? [String: Any])?["path"] as? String == "/images/cafe-sign-social.jpg",
            "the manifest records the share image separately"
        )
        for name in ["cafe-sign-400.webp", "cafe-sign-800.webp", "cafe-sign-400.jpg", "cafe-sign-800.jpg", "cafe-sign-social.jpg"] {
            let file = sidecarOutputs[0].appendingPathComponent(name)
            precondition(manager.fileExists(atPath: file.path), "\(name) was not written")
        }
        // The same renditions written as JSX. Cheap — the sidecars are string assembly, so
        // this needs no re-encoding — and it proves the flavour reaches the filename.
        var jsxSettings = sidecarSettings
        jsxSettings.webExport?.sidecars?.markupFlavour = .jsx
        let jsxFiles = try SidecarWriter.write(
            renditions: batch.renditions,
            outputDirectories: sidecarOutputs,
            settings: jsxSettings
        )
        precondition(
            jsxFiles.contains { $0.lastPathComponent == "snippet.jsx" },
            "expected a snippet.jsx, got \(jsxFiles.map(\.lastPathComponent))"
        )
        let jsxSnippet = try String(
            contentsOf: sidecarOutputs[0].appendingPathComponent("snippet.jsx"), encoding: .utf8
        )
        precondition(jsxSnippet.contains("srcSet="), "the written JSX camel-cases srcset")
        precondition(!jsxSnippet.contains("srcset="), "and drops the HTML spelling: \(jsxSnippet)")
        precondition(jsxSnippet.contains("dangerouslySetInnerHTML"), "structured data is set as HTML")
        print("Sidecar checks passed.")


        // Alt text end to end, on a real photograph — a synthetic fixture has nothing to
        // recognise, so this is skipped rather than asserted when none is available.
        let photoCandidates = [
            "/System/Library/Desktop Pictures/iMac Blue.heic",
            "/System/Library/Desktop Pictures/Mac Blue.heic"
        ].map(URL.init(fileURLWithPath:)).filter { FileManager.default.fileExists(atPath: $0.path) }

        if let photo = photoCandidates.first {
            // A low floor, because the point here is that the wiring produces something
            // and writes it in both places, not that the classifier is any good.
            let altSettings = AltText(isEnabled: true, engine: .labelsOnly, minimumConfidence: 0.02)
            let suggestions = await AltTextGenerator.generate(for: [photo], settings: altSettings)
            // The confidence floor is what keeps the feature honest, so demand that a
            // high one actually silences it. Nothing in this fixture is recognised
            // anywhere near this confidently.
            let demanding = AltText(isEnabled: true, engine: .labelsOnly, minimumConfidence: 0.99)
            let refused = await AltTextGenerator.generate(for: [photo], settings: demanding)
            precondition(refused[photo] == nil, "a high confidence floor must produce no suggestion, got \(refused)")

            // The guardrail on batch context: an image the recogniser cannot describe must
            // stay undescribed rather than borrowing the batch's sentence. Forty
            // photographs sharing one caption would be worse than forty blanks, so the
            // context must not be able to rescue a refusal.
            let contextual = AltText(
                isEnabled: true, engine: .automatic, minimumConfidence: 0.99,
                context: "Beirut café interior"
            )
            let stillRefused = await AltTextGenerator.generate(for: [photo], settings: contextual)
            precondition(
                stillRefused[photo] == nil,
                "context must not become a description on its own, got \(stillRefused)"
            )

            if let suggestion = suggestions[photo] {
                precondition(!suggestion.isEmpty, "a suggestion must not be empty")
                precondition(suggestion.count <= altSettings.maxLength, "a suggestion respects its length cap")
                precondition(!suggestion.hasSuffix("."), "alt text is a phrase, not a sentence")

                var altJobSettings = settings
                altJobSettings.webExport = WebExport(
                    isEnabled: true,
                    rights: RightsMetadata(descriptionPolicy: .fromAltText),
                    sidecars: Sidecars()
                )
                let altOut = outputs[0].appendingPathComponent("Trips/alt.jpg")
                _ = try ResizeEngine.resize(job: ResizeJob(
                    source: input, output: altOut, settings: altJobSettings, altText: suggestion
                ))
                guard let altSource = CGImageSourceCreateWithURL(altOut as CFURL, nil),
                      let altProps = CGImageSourceCopyPropertiesAtIndex(altSource, 0, nil) as? [CFString: Any],
                      let altIPTC = altProps[kCGImagePropertyIPTCDictionary] as? [CFString: Any] else {
                    preconditionFailure("alt-text output carries no IPTC")
                }
                precondition(
                    (altIPTC[kCGImagePropertyIPTCCaptionAbstract] as? String) == suggestion,
                    "the suggestion is written as the description"
                )

                // And it must reach the markup, in preference to a filename-derived title.
                let altEntry = SidecarWriter.group(
                    [Rendition(source: input, output: altOut, width: 320, height: 180, bytes: 10, altText: suggestion)],
                    settings: altJobSettings,
                    sidecars: Sidecars()
                )[0]
                let altMarkup = SidecarWriter.markup(for: altEntry, settings: altJobSettings, sidecars: Sidecars())
                precondition(altMarkup.contains("alt=\"\(suggestion)\""), "the suggestion reaches the markup: \(altMarkup)")
                print("Alt text checks passed (\"\(suggestion)\").")
            } else {
                print("Alt text: nothing recognised confidently in the fixture; wiring exercised, output skipped.")
            }
        } else {
            print("Alt text: no photographic fixture on this machine; skipped.")
        }

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

    /// A dark frame with one bright marker in it, so a crop can be asked whether it kept
    /// the subject. `marker` is in image coordinates with the origin at the bottom left.
    static func makeMarkedPNG(at url: URL, width: Int, height: Int, marker: CGRect) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(marker)
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
    }

    /// One pixel of a written file, in image coordinates with the origin at the bottom
    /// left — the same space the crop maths uses, so the assertion reads like the maths.
    static func samplePixel(
        _ url: URL,
        x: Int,
        fromBottom y: Int
    ) -> (red: UInt8, green: UInt8, blue: UInt8)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Slide the image so the wanted pixel lands on the context's only one.
        context.draw(
            image,
            in: CGRect(x: -x, y: -y, width: image.width, height: image.height)
        )
        return (pixel[0], pixel[1], pixel[2])
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
