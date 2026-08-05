import Foundation
import CoreGraphics
import ImageIO

/// Writes the files that describe an export: a manifest, ready-to-paste markup, and
/// optional inline placeholders.
///
/// Runs after the batch, from the renditions it recorded. Everything here is string
/// assembly over data the run already produced — nothing is re-derived, and nothing
/// reaches the network.
enum SidecarWriter {
    /// One source image and every file produced from it.
    struct Entry {
        let source: URL
        let slug: String
        let renditions: [Rendition]
        var placeholder: String?

        /// The rendition a browser falls back to when it cannot read `srcset`. The
        /// largest is the safest default: a browser old enough to ignore srcset is not
        /// the one to optimise bytes for.
        var fallback: Rendition? { renditions.last }
    }

    @discardableResult
    static func write(
        renditions: [Rendition],
        outputDirectories: [URL],
        settings: ResizeSettings
    ) throws -> [URL] {
        guard let sidecars = settings.webExport?.sidecars, sidecars.writesAnything,
              !renditions.isEmpty else { return [] }

        var written: [URL] = []
        // A batch can span several output folders, and each should describe only its own
        // contents — a manifest naming files in a sibling folder would be wrong wherever
        // it was deployed.
        for directory in outputDirectories {
            let owned = renditions.filter { $0.output.path.hasPrefix(directory.path) }
            guard !owned.isEmpty else { continue }
            let entries = group(owned, settings: settings, sidecars: sidecars)
            guard !entries.isEmpty else { continue }

            if sidecars.manifest {
                let url = directory.appendingPathComponent("manifest.json")
                try manifestJSON(entries, sidecars: sidecars).write(to: url, options: .atomic)
                written.append(url)
            }
            if sidecars.markupSnippet {
                let url = directory.appendingPathComponent("snippet.html")
                let markup = entries.map { self.markup(for: $0, settings: settings, sidecars: sidecars) }
                try Data(markup.joined(separator: "\n\n").utf8).write(to: url, options: .atomic)
                written.append(url)
            }
        }
        return written
    }

    static func group(
        _ renditions: [Rendition],
        settings: ResizeSettings,
        sidecars: Sidecars
    ) -> [Entry] {
        var order: [URL] = []
        var bySource: [URL: [Rendition]] = [:]
        for rendition in renditions {
            if bySource[rendition.source] == nil { order.append(rendition.source) }
            bySource[rendition.source, default: []].append(rendition)
        }
        return order.map { source in
            let sorted = (bySource[source] ?? []).sorted { $0.width < $1.width }
            var entry = Entry(
                source: source,
                slug: OutputNaming.slug(source.deletingPathExtension().lastPathComponent),
                renditions: sorted
            )
            if sidecars.placeholder == .base64DataURI, let smallest = sorted.first {
                entry.placeholder = placeholderDataURI(for: smallest, width: sidecars.placeholderWidth)
            }
            return entry
        }
    }

    // MARK: - Manifest

    static func manifestJSON(_ entries: [Entry], sidecars: Sidecars) throws -> Data {
        let images: [[String: Any]] = entries.map { entry in
            var image: [String: Any] = [
                "source": entry.source.lastPathComponent,
                "slug": entry.slug,
                "renditions": entry.renditions.map { rendition in
                    [
                        "path": path(for: rendition, sidecars: sidecars),
                        "width": rendition.width,
                        "height": rendition.height,
                        "format": rendition.format,
                        "bytes": rendition.bytes
                    ] as [String: Any]
                }
            ]
            if let placeholder = entry.placeholder { image["placeholder"] = placeholder }
            return image
        }
        return try JSONSerialization.data(
            withJSONObject: ["generator": "Image Resizer", "images": images],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    // MARK: - Markup

    /// Emits a plain `<img>` with a `srcset`.
    ///
    /// A `<picture>` element only earns its wrapper once there are alternative formats to
    /// choose between; with one format its `<source>` list would be empty and the markup
    /// would be strictly worse than an `<img>`. Format alternatives are not implemented,
    /// so this stays an `<img>` until they are.
    static func markup(for entry: Entry, settings: ResizeSettings, sidecars: Sidecars) -> String {
        guard let fallback = entry.fallback else { return "" }
        let srcset = entry.renditions
            .map { "\(path(for: $0, sidecars: sidecars)) \($0.width)w" }
            .joined(separator: ", ")

        var attributes = [
            "src=\"\(escape(path(for: fallback, sidecars: sidecars)))\"",
            "srcset=\"\(escape(srcset))\"",
            "sizes=\"\(escape(sidecars.sizesAttribute))\"",
            "width=\"\(fallback.width)\"",
            "height=\"\(fallback.height)\"",
            "alt=\"\(escape(altText(for: entry, settings: settings)))\"",
            "loading=\"lazy\"",
            "decoding=\"async\""
        ]
        if let placeholder = entry.placeholder {
            attributes.append("style=\"background-image:url(\(placeholder));background-size:cover\"")
        }
        return "<img \(attributes.joined(separator: "\n     "))>"
    }

    /// Alt text is required for the markup to be worth pasting, but the app cannot invent
    /// a description yet. The rights title policy is the only source available, so an
    /// empty `alt` is emitted rather than a guess — an empty alt is a valid declaration
    /// that an image is decorative, whereas a wrong one is worse than none.
    static func altText(for entry: Entry, settings: ResizeSettings) -> String {
        // A generated suggestion is a description of the picture, which is what alt text
        // is for. A title is a name for it — better than nothing, but second choice.
        if let suggestion = entry.renditions.compactMap(\.altText).first { return suggestion }
        guard let rights = settings.webExport?.rights else { return "" }
        return RightsWriter.resolve(rights.titlePolicy, source: entry.source, humanise: true) ?? ""
    }

    static func path(for rendition: Rendition, sidecars: Sidecars) -> String {
        let prefix = sidecars.pathPrefix
        guard !prefix.isEmpty else { return rendition.output.lastPathComponent }
        return prefix.hasSuffix("/")
            ? prefix + rendition.output.lastPathComponent
            : prefix + "/" + rendition.output.lastPathComponent
    }

    /// Minimal HTML attribute escaping. The values are filenames and user-entered text,
    /// so `&`, quotes, and angle brackets are the ones that can break the markup.
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Placeholder

    /// A very small JPEG, inline as a data URI, for showing while the real image loads.
    /// Encoded hard: at this size the point is average colour, not detail.
    static func placeholderDataURI(for rendition: Rendition, width: Int) -> String? {
        guard width > 0,
              let source = CGImageSourceCreateWithURL(rendition.output as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: width
              ] as CFDictionary) else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, OutputFormat.jpeg.typeIdentifier!, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, [
            kCGImageDestinationLossyCompressionQuality: 0.4
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return "data:image/jpeg;base64," + (data as Data).base64EncodedString()
    }
}
