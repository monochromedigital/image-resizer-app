import Foundation
import CoreGraphics
import ImageIO

enum WebPCodecError: LocalizedError {
    case toolsMissing
    case encodingFailed(String)
    case frameRenderingFailed

    var errorDescription: String? {
        switch self {
        case .toolsMissing: "The bundled WebP encoder could not be found."
        case .encodingFailed(let message): "WebP encoding failed: \(message)"
        case .frameRenderingFailed: "A WebP animation frame could not be rendered."
        }
    }
}

enum WebPCodec {
    static func resize(source: CGImageSource, isRaw: Bool, job: ResizeJob, settings: ResizeSettings) throws -> URL {
        guard let encoder = tool(named: "img2webp") else { throw WebPCodecError.toolsMissing }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { throw ResizeEngineError.unreadable(job.source) }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageResizer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        var frameURLs: [URL] = []
        var durations: [Int] = []
        for index in 0..<frameCount {
            let frame = try ResizeEngine.renderableFrame(source: source, index: index, isRaw: isRaw, settings: settings)
            let rendered = try ResizeEngine.render(
                frame.image,
                orientation: frame.orientation,
                target: frame.layout.outputSize,
                drawRect: frame.layout.drawRect,
                settings: settings,
                outputType: OutputFormat.webp.typeIdentifier!
            )
            let frameURL = temporary.appendingPathComponent(String(format: "frame-%06d.pam", index))
            try writePAM(rendered, to: frameURL)
            frameURLs.append(frameURL)
            durations.append(durationMilliseconds(properties: frame.properties))
        }

        // Resolved by JobPlanner along with the rest of the batch — see ResizeEngine.
        let output = job.output
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        func encodedData(quality: Double) throws -> Data {
            let attempt = temporary.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: attempt, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: attempt) }
            let temporaryOutput = attempt.appendingPathComponent("encoded.webp")
            let qualityPercent = max(1, min(100, Int((quality * 100).rounded())))
            var arguments = ["-loop", String(loopCount(source: source)), "-mixed", "-min_size"]
            for (index, frame) in frameURLs.enumerated() {
                arguments += ["-d", String(durations[index]), "-lossy", "-q", String(qualityPercent), "-m", "4", frame.path]
            }
            arguments += ["-o", temporaryOutput.path]
            try run(encoder, arguments: arguments)

            if settings.preserveMetadata, sourceType(source) == "org.webmproject.webp" {
                try copyWebPMetadata(
                    from: job.source,
                    encoded: temporaryOutput,
                    temporaryDirectory: attempt,
                    removeLocation: settings.removeLocation
                )
            }
            return try Data(contentsOf: temporaryOutput)
        }

        let data: Data
        if settings.targetFileSizeEnabled, let targetBytes = settings.targetFileSizeBytes {
            data = try ResizeEngine.targetSizedData(
                maximumQuality: settings.quality,
                targetBytes: targetBytes,
                encode: encodedData
            )
        } else {
            data = try encodedData(quality: settings.quality)
        }
        do {
            try data.write(to: output, options: .atomic)
        } catch {
            throw ResizeEngineError.cannotWrite(output)
        }
        return output
    }

    private static func writePAM(_ image: CGImage, to url: URL) throws {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let values = buffer.bindMemory(to: UInt8.self)
            for pixel in 0..<(width * height) {
                let offset = pixel * 4
                let alpha = Int(values[offset + 3])
                if alpha > 0 && alpha < 255 {
                    values[offset] = UInt8(min(255, Int(values[offset]) * 255 / alpha))
                    values[offset + 1] = UInt8(min(255, Int(values[offset + 1]) * 255 / alpha))
                    values[offset + 2] = UInt8(min(255, Int(values[offset + 2]) * 255 / alpha))
                }
            }
            return true
        }
        guard rendered else { throw WebPCodecError.frameRenderingFailed }
        let header = "P7\nWIDTH \(width)\nHEIGHT \(height)\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n"
        var output = Data(header.utf8)
        output.append(pixels)
        try output.write(to: url, options: .atomic)
    }

    private static func durationMilliseconds(properties: [CFString: Any]?) -> Int {
        let dictionaries: [CFString] = [kCGImagePropertyWebPDictionary, kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyHEICSDictionary]
        for dictionaryKey in dictionaries {
            guard let dictionary = properties?[dictionaryKey] as? [CFString: Any] else { continue }
            let keys: [CFString] = [
                kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime,
                kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime,
                kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime,
                kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime
            ]
            for key in keys {
                if let seconds = (dictionary[key] as? NSNumber)?.doubleValue, seconds > 0 {
                    return max(1, Int((seconds * 1000).rounded()))
                }
            }
        }
        return 100
    }

    private static func loopCount(source: CGImageSource) -> Int {
        guard let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] else { return 0 }
        let candidates: [(CFString, CFString)] = [
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPLoopCount),
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFLoopCount),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGLoopCount),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSLoopCount)
        ]
        for (dictionaryKey, loopKey) in candidates {
            if let dictionary = properties[dictionaryKey] as? [CFString: Any],
               let count = (dictionary[loopKey] as? NSNumber)?.intValue {
                return count
            }
        }
        return 0
    }

    private static func sourceType(_ source: CGImageSource) -> String? {
        CGImageSourceGetType(source) as String?
    }

    private static func copyWebPMetadata(
        from source: URL,
        encoded: URL,
        temporaryDirectory: URL,
        removeLocation: Bool
    ) throws {
        guard let mux = tool(named: "webpmux") else { return }
        var current = encoded
        let chunks = removeLocation ? ["icc"] : ["icc", "exif", "xmp"]
        for chunk in chunks {
            let chunkFile = temporaryDirectory.appendingPathComponent("metadata.\(chunk)")
            guard (try? run(mux, arguments: ["-get", chunk, source.path, "-o", chunkFile.path])) != nil,
                  FileManager.default.fileExists(atPath: chunkFile.path) else { continue }
            let next = temporaryDirectory.appendingPathComponent("with-\(chunk).webp")
            try run(mux, arguments: ["-set", chunk, chunkFile.path, current.path, "-o", next.path])
            if current != encoded { try? FileManager.default.removeItem(at: current) }
            current = next
        }
        if current != encoded {
            try FileManager.default.removeItem(at: encoded)
            try FileManager.default.moveItem(at: current, to: encoded)
        }
    }

    private static func run(_ executable: URL, arguments: [String]) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WebPCodecError.encodingFailed(message?.isEmpty == false ? message! : "encoder exited with status \(process.terminationStatus)")
        }
    }

    private static func tool(named name: String) -> URL? {
        let manager = FileManager.default
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("WebPTools/\(name)"),
            URL(fileURLWithPath: manager.currentDirectoryPath).appendingPathComponent("Vendor/WebPTools/\(name)")
        ].compactMap { $0 }
        return candidates.first { manager.isExecutableFile(atPath: $0.path) }
    }

}
