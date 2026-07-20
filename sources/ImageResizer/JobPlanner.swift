import Foundation
import ImageIO

enum JobPlanner {
    static func plan(sources: [URL], settings: ResizeSettings) throws -> ([ResizeJob], [URL], Int) {
        var jobs: [ResizeJob] = []
        var outputs: [URL] = []
        var skipped = 0
        let fileManager = FileManager.default

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
                    guard isReadableImage(file) else { skipped += 1; continue }
                    let relative = relativePath(of: file, beneath: source)
                    let destination = output.appendingPathComponent(relative)
                    jobs.append(ResizeJob(source: file, destination: destination))
                }
            } else if isReadableImage(source) {
                let output = outputDirectory(forFile: source, settings: settings)
                if !outputs.contains(output) { outputs.append(output) }
                jobs.append(ResizeJob(source: source, destination: output.appendingPathComponent(source.lastPathComponent)))
            } else {
                skipped += 1
            }
        }
        return (jobs, outputs, skipped)
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

    static func isReadableImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}
