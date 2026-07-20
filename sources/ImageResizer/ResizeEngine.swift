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

    var errorDescription: String? {
        switch self {
        case .unreadable(let url): "Could not read \(url.lastPathComponent)."
        case .unsupportedOutput(let type): "This Mac cannot write \(type) images."
        case .cannotCreateImage: "Could not render the resized image."
        case .cannotWrite(let url): "Could not write \(url.lastPathComponent)."
        }
    }
}

struct ResizeEngine {
    static func process(
        jobs: [ResizeJob],
        skipped: Int,
        settings: ResizeSettings,
        control: ProcessingControl,
        onProgress: @escaping @Sendable (BatchProgress) -> Void
    ) async -> BatchResult {
        await Task.detached(priority: .userInitiated) {
            var progress = BatchProgress(skipped: skipped, total: jobs.count + skipped)
            var errors: [String] = []
            var outputs = Set<URL>()

            for job in jobs {
                do {
                    try control.checkpoint()
                    progress.currentName = job.source.lastPathComponent
                    onProgress(progress)
                    let destination = try resize(job: job, settings: settings)
                    outputs.insert(destination.deletingLastPathComponent())
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
            return BatchResult(progress: progress, outputDirectories: Array(outputs), errors: errors)
        }.value
    }

    static func resize(job: ResizeJob, settings: ResizeSettings) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(job.source as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ResizeEngineError.unreadable(job.source)
        }

        let sourceType = CGImageSourceGetType(source)
        let wantsWebP = settings.format == .webp
            || (settings.format == .original && sourceType as String? == OutputFormat.webp.typeIdentifier as String?)
        if wantsWebP {
            return try WebPCodec.resize(source: source, job: job, settings: settings)
        }
        let writableTypes = CGImageDestinationCopyTypeIdentifiers() as! [String]
        let isRaw = sourceType.map { !writableTypes.contains($0 as String) } ?? true
        let requestedType: CFString = {
            if settings.format == .original {
                return (isRaw ? OutputFormat.jpeg.typeIdentifier : sourceType) ?? OutputFormat.jpeg.typeIdentifier!
            }
            return settings.format.typeIdentifier!
        }()
        guard writableTypes.contains(requestedType as String) else {
            throw ResizeEngineError.unsupportedOutput(settings.format.rawValue)
        }

        let outputExtension = extensionFor(type: requestedType, fallback: job.source.pathExtension)
        let requestedURL = job.destination
            .deletingPathExtension()
            .appendingPathExtension(outputExtension)
        try FileManager.default.createDirectory(
            at: requestedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let outputURL = availableURL(for: requestedURL)

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
            guard let image = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCache: true] as CFDictionary) else {
                throw ResizeEngineError.cannotCreateImage
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let orientedSize = orientation >= 5 && orientation <= 8
                ? CGSize(width: image.height, height: image.width)
                : CGSize(width: image.width, height: image.height)
            let target = ResizeMath.fittedSize(source: orientedSize, width: settings.width, height: settings.height)
            let rendered = try render(image, orientation: orientation, target: target, settings: settings, outputType: requestedType)
            var outputProperties = settings.preserveMetadata ? (properties ?? [:]) : [:]
            outputProperties[kCGImagePropertyOrientation] = 1
            outputProperties[kCGImagePropertyPixelWidth] = Int(target.width)
            outputProperties[kCGImagePropertyPixelHeight] = Int(target.height)
            if settings.removeLocation { removeLocation(from: &outputProperties) }
            if requestedType == OutputFormat.jpeg.typeIdentifier || requestedType == OutputFormat.heic.typeIdentifier {
                outputProperties[kCGImageDestinationLossyCompressionQuality] = settings.quality
            }
            CGImageDestinationAddImage(destination, rendered, outputProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: outputURL)
            throw ResizeEngineError.cannotWrite(outputURL)
        }
        return outputURL
    }

    static func render(
        _ image: CGImage,
        orientation: Int,
        target: CGSize,
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
        applyOrientation(orientation, context: context, target: target)
        let drawSize = orientation >= 5 && orientation <= 8
            ? CGSize(width: target.height, height: target.width)
            : target
        context.draw(image, in: CGRect(origin: .zero, size: drawSize))
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

    private static func removeLocation(from properties: inout [CFString: Any]) {
        properties.removeValue(forKey: kCGImagePropertyGPSDictionary)
    }

    private static func availableURL(for requested: URL) -> URL {
        guard FileManager.default.fileExists(atPath: requested.path) else { return requested }
        let directory = requested.deletingLastPathComponent()
        let stem = requested.deletingPathExtension().lastPathComponent
        let ext = requested.pathExtension
        var number = 2
        while true {
            let candidate = directory.appendingPathComponent("\(stem)-\(number)").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }

    private static func extensionFor(type: CFString, fallback: String) -> String {
        switch type as String {
        case "public.jpeg": "jpg"
        case "public.png": "png"
        case "public.heic": "heic"
        case "public.tiff": "tiff"
        case "com.compuserve.gif": "gif"
        case "org.webmproject.webp": "webp"
        default: fallback.isEmpty ? "jpg" : fallback.lowercased()
        }
    }
}
