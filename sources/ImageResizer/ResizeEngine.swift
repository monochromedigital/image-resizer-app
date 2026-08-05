import Foundation
import AppKit
import CoreGraphics
import ImageIO

final class ProcessingControl: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var cancelled = false

    func setPaused(_ value: Bool) { lock.withLock { paused = value } }
    func cancel() { lock.withLock { cancelled = true; paused = false } }

    func checkpoint() throws {
        while lock.withLock({ paused }) {
            if lock.withLock({ cancelled }) { throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}

enum ResizeEngineError: LocalizedError {
    case unreadable(URL)
    case unsupportedOutput(String)
    case cannotCreateImage
    case cannotWrite(URL)
    case targetFileSizeTooSmall(Int)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url): "Could not read \(url.lastPathComponent)."
        case .unsupportedOutput(let type): "This Mac cannot write \(type) images."
        case .cannotCreateImage: "Could not render the resized image."
        case .cannotWrite(let url): "Could not write \(url.lastPathComponent)."
        case .targetFileSizeTooSmall(let bytes):
            "The file cannot fit under \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) at the minimum quality. Increase the limit or reduce the dimensions."
        }
    }
}

struct ResizeEngine {
    struct RenderableFrame {
        let image: CGImage
        let properties: [CFString: Any]?
        let orientation: Int
        let layout: ResizeLayout
    }

    static func process(
        jobs: [ResizeJob],
        skipped: Int,
        control: ProcessingControl,
        onProgress: @escaping @Sendable (BatchProgress) -> Void
    ) async -> BatchResult {
        await Task.detached(priority: .userInitiated) {
            var progress = BatchProgress(skipped: skipped, total: jobs.count + skipped)
            var errors: [String] = []
            var outputs = Set<URL>()
            var renditions: [Rendition] = []

            for job in jobs {
                do {
                    try control.checkpoint()
                    progress.currentName = job.source.lastPathComponent
                    onProgress(progress)
                    let destination = try resize(job: job)
                    outputs.insert(destination.deletingLastPathComponent())
                    if var rendition = rendition(source: job.source, output: destination) {
                        rendition.altText = job.altText
                        renditions.append(rendition)
                    }
                    progress.completed += 1
                } catch is CancellationError {
                    break
                } catch {
                    progress.failed += 1
                    errors.append("\(job.source.lastPathComponent): \(error.localizedDescription)")
                }
                onProgress(progress)
            }

            progress.currentName = ""
            onProgress(progress)
            return BatchResult(progress: progress, outputDirectories: Array(outputs), errors: errors, renditions: renditions)
        }.value
    }

    static func resize(job: ResizeJob) throws -> URL {
        let settings = job.settings
        guard let source = CGImageSourceCreateWithURL(job.source as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ResizeEngineError.unreadable(job.source)
        }

        let sourceType = CGImageSourceGetType(source)
        let writableTypes = CGImageDestinationCopyTypeIdentifiers() as! [String]
        let isRaw = sourceType.map { !writableTypes.contains($0 as String) } ?? true
        if OutputType.usesWebPCodec(sourceType: sourceType, format: settings.format) {
            return try WebPCodec.resize(source: source, isRaw: isRaw, job: job)
        }
        let requestedType = OutputType.resolve(
            sourceType: sourceType,
            isRaw: isRaw,
            format: settings.format
        )
        guard writableTypes.contains(requestedType as String) else {
            throw ResizeEngineError.unsupportedOutput(settings.format.rawValue)
        }

        // The filename was decided by JobPlanner, which resolved collisions across the
        // whole batch. The engine only has to make sure the folder exists.
        let outputURL = job.output
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if OutputType.isLossy(requestedType),
           settings.targetFileSizeEnabled,
           let targetBytes = settings.targetFileSizeBytes {
            return try resizeToTargetSize(
                source: source,
                sourceURL: job.source,
                altText: job.altText,
                isRaw: isRaw,
                outputURL: outputURL,
                outputType: requestedType,
                targetBytes: targetBytes,
                settings: settings
            )
        }

        let frameCount = CGImageSourceGetCount(source)
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            requestedType,
            frameCount,
            nil
        ) else { throw ResizeEngineError.cannotWrite(outputURL) }

        if settings.preserveMetadata,
           var container = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] {
            if settings.removeLocation { removeLocation(from: &container) }
            CGImageDestinationSetProperties(destination, container as CFDictionary)
        }

        for index in 0..<frameCount {
            let frame = try renderableFrame(source: source, index: index, isRaw: isRaw, settings: settings)
            let rendered = try render(
                frame.image,
                orientation: frame.orientation,
                target: frame.layout.outputSize,
                drawRect: frame.layout.drawRect,
                settings: settings,
                outputType: requestedType
            )
            var outputProperties = settings.preserveMetadata ? (frame.properties ?? [:]) : [:]
            outputProperties[kCGImagePropertyOrientation] = 1
            outputProperties[kCGImagePropertyPixelWidth] = Int(frame.layout.outputSize.width)
            outputProperties[kCGImagePropertyPixelHeight] = Int(frame.layout.outputSize.height)
            if settings.removeLocation { removeLocation(from: &outputProperties) }
            if OutputType.isLossy(requestedType) {
                outputProperties[kCGImageDestinationLossyCompressionQuality] = settings.quality
            }
            applyRights(to: &outputProperties, settings: settings, source: job.source, altText: job.altText)
            // XMP has no property-dictionary equivalent, so writing xmpRights:WebStatement
            // or plus:Licensor means a different destination call. Only taken when there
            // is XMP to write — AddImage stays the path for everything else.
            if let metadata = rightsMetadata(for: settings) {
                CGImageDestinationAddImageAndMetadata(destination, rendered, metadata, outputProperties as CFDictionary)
            } else {
                CGImageDestinationAddImage(destination, rendered, outputProperties as CFDictionary)
            }
        }

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: outputURL)
            throw ResizeEngineError.cannotWrite(outputURL)
        }
        return outputURL
    }

    /// Bisects quality until the encoded file fits `targetBytes`.
    ///
    /// Works for any type that honours the lossy-quality key; `targetSizedData` was
    /// always generic and only this caller was tied to JPEG. Passing `outputType` through
    /// also matters for correctness rather than tidiness: `render` decides whether to
    /// keep an alpha channel from it, and hardcoding JPEG here would have flattened
    /// transparency out of AVIF and HEIC output.
    private static func resizeToTargetSize(
        source: CGImageSource,
        sourceURL: URL,
        altText: String?,
        isRaw: Bool,
        outputURL: URL,
        outputType: CFString,
        targetBytes: Int,
        settings: ResizeSettings
    ) throws -> URL {
        struct Frame {
            let image: CGImage
            let properties: [CFString: Any]
        }

        var frames: [Frame] = []
        for index in 0..<CGImageSourceGetCount(source) {
            let frame = try renderableFrame(source: source, index: index, isRaw: isRaw, settings: settings)
            let rendered = try render(
                frame.image,
                orientation: frame.orientation,
                target: frame.layout.outputSize,
                drawRect: frame.layout.drawRect,
                settings: settings,
                outputType: outputType
            )
            var properties = settings.preserveMetadata ? (frame.properties ?? [:]) : [:]
            properties[kCGImagePropertyOrientation] = 1
            properties[kCGImagePropertyPixelWidth] = Int(frame.layout.outputSize.width)
            properties[kCGImagePropertyPixelHeight] = Int(frame.layout.outputSize.height)
            if settings.removeLocation { removeLocation(from: &properties) }
            applyRights(to: &properties, settings: settings, source: sourceURL, altText: altText)
            frames.append(Frame(image: rendered, properties: properties))
        }

        var containerProperties = settings.preserveMetadata
            ? (CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:])
            : [:]
        if settings.removeLocation { removeLocation(from: &containerProperties) }

        let data = try targetSizedData(
            maximumQuality: settings.quality,
            targetBytes: targetBytes
        ) { quality in
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                encoded as CFMutableData,
                outputType,
                frames.count,
                nil
            ) else { throw ResizeEngineError.cannotWrite(outputURL) }
            if !containerProperties.isEmpty {
                CGImageDestinationSetProperties(destination, containerProperties as CFDictionary)
            }
            let metadata = rightsMetadata(for: settings)
            for frame in frames {
                var properties = frame.properties
                properties[kCGImageDestinationLossyCompressionQuality] = quality
                if let metadata {
                    CGImageDestinationAddImageAndMetadata(destination, frame.image, metadata, properties as CFDictionary)
                } else {
                    CGImageDestinationAddImage(destination, frame.image, properties as CFDictionary)
                }
            }
            guard CGImageDestinationFinalize(destination) else {
                throw ResizeEngineError.cannotWrite(outputURL)
            }
            return encoded as Data
        }
        do {
            try data.write(to: outputURL, options: .atomic)
        } catch {
            throw ResizeEngineError.cannotWrite(outputURL)
        }
        return outputURL
    }

    static func targetSizedData(
        maximumQuality: Double,
        targetBytes: Int,
        minimumQuality: Double = 0.01,
        encode: (Double) throws -> Data
    ) throws -> Data {
        let maximum = min(1, max(minimumQuality, maximumQuality))
        let maximumData = try encode(maximum)
        if maximumData.count <= targetBytes { return maximumData }

        let minimumData = try encode(minimumQuality)
        guard minimumData.count <= targetBytes else {
            throw ResizeEngineError.targetFileSizeTooSmall(targetBytes)
        }

        var lower = minimumQuality
        var upper = maximum
        var best = minimumData
        for _ in 0..<8 {
            let candidate = (lower + upper) / 2
            let data = try encode(candidate)
            if data.count <= targetBytes {
                lower = candidate
                best = data
            } else {
                upper = candidate
            }
        }
        return best
    }

    static func renderableFrame(
        source: CGImageSource,
        index: Int,
        isRaw: Bool,
        settings: ResizeSettings
    ) throws -> RenderableFrame {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1

        var fallbackImage: CGImage?
        let storedSize: CGSize
        if let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
           width > 0, height > 0 {
            storedSize = CGSize(width: width, height: height)
        } else {
            fallbackImage = CGImageSourceCreateImageAtIndex(
                source,
                index,
                [kCGImageSourceShouldCache: true] as CFDictionary
            )
            guard let fallbackImage else { throw ResizeEngineError.cannotCreateImage }
            storedSize = CGSize(width: fallbackImage.width, height: fallbackImage.height)
        }

        let orientedSize = orientation >= 5 && orientation <= 8
            ? CGSize(width: storedSize.height, height: storedSize.width)
            : storedSize
        let layout = ResizeMath.layout(source: orientedSize, settings: settings)

        if isRaw {
            // Camera RAW decoders can return high-bit-depth images that do not draw correctly
            // into the app's 8-bit output context. Prefer the camera's embedded, color-rendered
            // preview and let ImageIO generate one only when the RAW file has no preview.
            let maxPixelSize = max(1, Int(max(layout.drawRect.width, layout.drawRect.height).rounded(.up)))
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ]
            if let preview = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) {
                return RenderableFrame(image: preview, properties: properties, orientation: 1, layout: layout)
            }
        }

        guard let image = fallbackImage ?? CGImageSourceCreateImageAtIndex(
            source,
            index,
            [kCGImageSourceShouldCache: true] as CFDictionary
        ) else { throw ResizeEngineError.cannotCreateImage }
        return RenderableFrame(image: image, properties: properties, orientation: orientation, layout: layout)
    }

    static func render(
        _ image: CGImage,
        orientation: Int,
        target: CGSize,
        drawRect: CGRect? = nil,
        settings: ResizeSettings,
        outputType: CFString
    ) throws -> CGImage {
        let width = Int(target.width)
        let height = Int(target.height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let hasAlpha = outputType != OutputFormat.jpeg.typeIdentifier
        let bitmapInfo = hasAlpha
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { throw ResizeEngineError.cannotCreateImage }

        if !hasAlpha {
            context.setFillColor(CGColor(
                red: settings.backgroundRed,
                green: settings.backgroundGreen,
                blue: settings.backgroundBlue,
                alpha: 1
            ))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.interpolationQuality = .high
        let contentRect = drawRect ?? CGRect(origin: .zero, size: target)
        context.saveGState()
        context.translateBy(x: contentRect.origin.x, y: contentRect.origin.y)
        applyOrientation(orientation, context: context, target: contentRect.size)
        let drawSize = orientation >= 5 && orientation <= 8
            ? CGSize(width: contentRect.height, height: contentRect.width)
            : contentRect.size
        context.draw(image, in: CGRect(origin: .zero, size: drawSize))
        context.restoreGState()
        guard let result = context.makeImage() else { throw ResizeEngineError.cannotCreateImage }
        return result
    }

    private static func applyOrientation(_ orientation: Int, context: CGContext, target: CGSize) {
        let w = target.width
        let h = target.height
        switch orientation {
        case 2: context.translateBy(x: w, y: 0); context.scaleBy(x: -1, y: 1)
        case 3: context.translateBy(x: w, y: h); context.rotate(by: .pi)
        case 4: context.translateBy(x: 0, y: h); context.scaleBy(x: 1, y: -1)
        case 5: context.translateBy(x: w, y: 0); context.rotate(by: .pi / 2); context.scaleBy(x: 1, y: -1)
        case 6: context.translateBy(x: w, y: 0); context.rotate(by: .pi / 2)
        case 7: context.translateBy(x: w, y: h); context.rotate(by: .pi / 2); context.scaleBy(x: -1, y: 1)
        case 8: context.translateBy(x: 0, y: h); context.rotate(by: -.pi / 2)
        default: break
        }
    }

    /// Records what was actually written, read back from the file's header rather than
    /// from what was requested — the two can differ, and the sidecars describe files a
    /// browser will fetch, so they have to match reality.
    private static func rendition(source: URL, output: URL) -> Rendition? {
        guard let imageSource = CGImageSourceCreateWithURL(output as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        return Rendition(source: source, output: output, width: width, height: height, bytes: bytes ?? 0)
    }

    private static func rightsMetadata(for settings: ResizeSettings) -> CGImageMetadata? {
        guard let rights = settings.webExport?.rights, rights.hasContent else { return nil }
        return RightsWriter.metadata(rights: rights)
    }

    private static func applyRights(
        to properties: inout [CFString: Any],
        settings: ResizeSettings,
        source: URL,
        altText: String?
    ) {
        guard let rights = settings.webExport?.rights, rights.hasContent else { return }
        let existing = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        if let iptc = RightsWriter.iptcDictionary(existing: existing, rights: rights, source: source, altText: altText) {
            properties[kCGImagePropertyIPTCDictionary] = iptc
        }
    }

    private static func removeLocation(from properties: inout [CFString: Any]) {
        properties.removeValue(forKey: kCGImagePropertyGPSDictionary)
    }

}
