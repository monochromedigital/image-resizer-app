import Foundation
import ImageIO

enum JobPlanner {
    /// What reading the header of a candidate file tells us.
    struct Probe {
        let sourceType: CFString?
        let isRaw: Bool
        /// Orientation-corrected pixel size, so a rotated source ladders against the
        /// dimensions it will actually be written at. `nil` when the header omits them.
        let pixelSize: CGSize?
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
                    jobs.append(contentsOf: self.jobs(
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
                jobs.append(contentsOf: self.jobs(
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

    /// Resolves the jobs one source produces — one per format per ladder rung, or a
    /// single job when neither applies.
    ///
    /// Naming happens here rather than during encoding so that every filename in a batch
    /// is known before the first byte is written. That is what makes collisions decidable
    /// across the whole batch and, later, what lets the sidecar manifest describe the
    /// complete output set.
    private static func jobs(
        for file: URL,
        probe: Probe,
        directory: URL,
        relativeDirectory: String,
        naming: Naming,
        settings: ResizeSettings,
        reservations: NameReservations
    ) -> [ResizeJob] {
        var base = directory
        if !relativeDirectory.isEmpty {
            base = base.appendingPathComponent(relativeDirectory, isDirectory: true)
        }

        // Formats outermost so one source's files stay contiguous and in the order the
        // markup offers them. The extension has to be resolved per format, not once per
        // source, or every rendition would be named after the fallback.
        let responsive = FormatMatrix.expand(settings).flatMap { formatted -> [ResizeJob] in
            let type = OutputType.resolve(
                sourceType: probe.sourceType,
                isRaw: probe.isRaw,
                format: formatted.format
            )
            let fileExtension = OutputType.usesWebPCodec(sourceType: probe.sourceType, format: formatted.format)
                ? "webp"
                : OutputType.fileExtension(for: type, fallback: file.pathExtension)

            return SizeLadder.expand(formatted, sourceSize: probe.pixelSize).map { rung in
                // The same layout maths the engine will run, so {width} and {height} name
                // the file after the size it is actually written at rather than the size
                // asked for.
                let outputSize = probe.pixelSize.map { ResizeMath.layout(source: $0, settings: rung).outputSize }
                let stem = OutputNaming.stem(
                    source: file,
                    naming: naming,
                    filenameSuffix: rung.filenameSuffix,
                    outputExtension: fileExtension,
                    outputSize: outputSize
                )
                let requested = base.appendingPathComponent(stem).appendingPathExtension(fileExtension)
                return ResizeJob(source: file, output: reservations.reserve(requested), settings: rung)
            }
        }

        guard let social = settings.webExport?.social, social.isValid,
              let shareJob = socialJob(
                  for: file,
                  base: base,
                  naming: naming,
                  settings: settings,
                  social: social,
                  reservations: reservations
              )
        else { return responsive }
        return responsive + [shareJob]
    }

    /// The one extra rendition a link preview needs.
    ///
    /// Neither the ladder nor the format matrix applies: a share image is a single fixed
    /// shape, and the platforms that scrape it are the most conservative readers of
    /// anything a site serves — JPEG is the format all of them take.
    private static func socialJob(
        for file: URL,
        base: URL,
        naming: Naming,
        settings: ResizeSettings,
        social: SocialImage,
        reservations: NameReservations
    ) -> ResizeJob? {
        var derived = settings
        derived.mode = .fill
        derived.width = social.width
        derived.height = social.height
        derived.longEdge = nil
        derived.percentage = nil
        derived.format = .jpeg
        derived.webExport?.ladder = nil
        derived.webExport?.formats = nil

        // The marker rather than the run's template, because every token the template
        // could use — {width} above all — is one a ladder rung might resolve to the same
        // string, and two files cannot answer to one name.
        var socialNaming = naming
        socialNaming.template = (naming.style == .slug ? "{slug}" : "{original}") + social.nameMarker
        let stem = OutputNaming.stem(
            source: file,
            naming: socialNaming,
            filenameSuffix: "",
            outputExtension: "jpg"
        )
        guard !stem.isEmpty else { return nil }
        let requested = base.appendingPathComponent(stem).appendingPathExtension("jpg")
        return ResizeJob(
            source: file,
            output: reservations.reserve(requested),
            settings: derived,
            role: .social
        )
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
        return Probe(sourceType: sourceType, isRaw: isRaw, pixelSize: pixelSize(of: source))
    }

    /// Reads the dimensions from the header without decoding the image. Mirrors the
    /// orientation swap `ResizeEngine.renderableFrame` applies, so the planner and the
    /// engine agree on how large the output will be.
    private static func pixelSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return orientation >= 5 && orientation <= 8
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    static func isReadableImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}
