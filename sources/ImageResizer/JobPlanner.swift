import Foundation
import ImageIO

enum JobPlanner {
    /// What reading the header of a candidate file tells us.
    struct Probe {
        let sourceType: CFString?
        let isRaw: Bool
    }

    static func plan(sources: [URL], settings: ResizeSettings) throws -> ([ResizeJob], [URL], Int) {
        var jobs: [ResizeJob] = []
        var outputs: [URL] = []
        var skipped = 0
        let fileManager = FileManager.default
        let writableTypes = Set(CGImageDestinationCopyTypeIdentifiers() as! [String])
        let naming = settings.webExport?.naming ?? .legacy
        let reservations = NameReservations()

        for source in sources {
            let values = try source.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                let output = outputDirectory(forFolder: source, settings: settings)
                outputs.append(output)
                guard let enumerator = fileManager.enumerator(
                    at: source,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                for case let file as URL in enumerator {
                    if file.standardizedFileURL == output.standardizedFileURL {
                        enumerator.skipDescendants()
                        continue
                    }
                    let fileValues = try? file.resourceValues(forKeys: [.isRegularFileKey])
                    guard fileValues?.isRegularFile == true else { continue }
                    guard let probe = probe(file, writableTypes: writableTypes) else {
                        skipped += 1
                        continue
                    }
                    let relative = relativePath(of: file, beneath: source)
                    jobs.append(job(
                        for: file,
                        probe: probe,
                        directory: output,
                        relativeDirectory: (relative as NSString).deletingLastPathComponent,
                        naming: naming,
                        settings: settings,
                        reservations: reservations
                    ))
                }
            } else if let probe = probe(source, writableTypes: writableTypes) {
                let output = outputDirectory(forFile: source, settings: settings)
                if !outputs.contains(output) { outputs.append(output) }
                jobs.append(job(
                    for: source,
                    probe: probe,
                    directory: output,
                    relativeDirectory: "",
                    naming: naming,
                    settings: settings,
                    reservations: reservations
                ))
            } else {
                skipped += 1
            }
        }
        return (jobs, outputs, skipped)
    }

    /// Resolves one job's final output path. Naming happens here rather than during
    /// encoding so that every filename in a batch is known before the first byte is
    /// written — which is what makes collisions decidable and, later, what lets the
    /// sidecar manifest describe the whole output set.
    private static func job(
        for file: URL,
        probe: Probe,
        directory: URL,
        relativeDirectory: String,
        naming: Naming,
        settings: ResizeSettings,
        reservations: NameReservations
    ) -> ResizeJob {
        let type = OutputType.resolve(
            sourceType: probe.sourceType,
            isRaw: probe.isRaw,
            format: settings.format
        )
        let fileExtension = OutputType.usesWebPCodec(sourceType: probe.sourceType, format: settings.format)
            ? "webp"
            : OutputType.fileExtension(for: type, fallback: file.pathExtension)
        let stem = OutputNaming.stem(
            source: file,
            naming: naming,
            filenameSuffix: settings.filenameSuffix,
            outputExtension: fileExtension
        )
        var base = directory
        if !relativeDirectory.isEmpty {
            base = base.appendingPathComponent(relativeDirectory, isDirectory: true)
        }
        let requested = base.appendingPathComponent(stem).appendingPathExtension(fileExtension)
        return ResizeJob(source: file, output: reservations.reserve(requested))
    }

    static func outputDirectory(forFolder source: URL, settings: ResizeSettings) -> URL {
        let named = source.lastPathComponent + " - Resized"
        if settings.useCustomDestination, let custom = settings.customDestination {
            return custom.appendingPathComponent(named, isDirectory: true)
        }
        return source.deletingLastPathComponent().appendingPathComponent(named, isDirectory: true)
    }

    static func outputDirectory(forFile source: URL, settings: ResizeSettings) -> URL {
        if settings.useCustomDestination, let custom = settings.customDestination {
            return custom.appendingPathComponent("Resized Images", isDirectory: true)
        }
        return source.deletingLastPathComponent().appendingPathComponent("Resized Images", isDirectory: true)
    }

    static func relativePath(of file: URL, beneath root: URL) -> String {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return file.lastPathComponent }
        return String(filePath.dropFirst(rootPath.count))
    }

    /// Reads just enough of the file to know whether it is an image and what kind.
    /// Returns `nil` for anything ImageIO cannot open.
    static func probe(_ url: URL, writableTypes: Set<String>) -> Probe? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let sourceType = CGImageSourceGetType(source)
        // Anything ImageIO can read but not write is treated as camera RAW.
        let isRaw = sourceType.map { !writableTypes.contains($0 as String) } ?? true
        return Probe(sourceType: sourceType, isRaw: isRaw)
    }

    static func isReadableImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}
