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
        /// Every rendition written in one format, sorted by width.
        struct FormatGroup {
            let fileExtension: String
            let renditions: [Rendition]
        }

        let source: URL
        let slug: String
        /// Grouped by format, in the order a browser should try them. The last group is
        /// the fallback — the format every browser can read — and is what the `<img>`
        /// points at.
        let formats: [FormatGroup]
        var placeholder: String?

        /// Flat and width-ordered within each format, which is the order the manifest
        /// lists them in.
        var renditions: [Rendition] { formats.flatMap(\.renditions) }

        /// The rendition a browser falls back to when it can read neither `<source>` nor
        /// `srcset`. The largest is the safest default: a browser old enough to ignore
        /// srcset is not the one to optimise bytes for.
        var fallback: Rendition? { formats.last?.renditions.last }
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
                var blocks = entries.enumerated().map { index, entry in
                    self.markup(
                        for: entry,
                        settings: settings,
                        sidecars: sidecars,
                        isHero: sidecars.prioritiseFirstImage && index == 0
                    )
                }
                // Ahead of the markup, because it describes the whole set rather than any
                // one image, and because that is where a page carries it.
                if sidecars.structuredData,
                   let json = structuredData(for: entries, settings: settings, sidecars: sidecars) {
                    blocks.insert(json, at: 0)
                }
                try Data(blocks.joined(separator: "\n\n").utf8).write(to: url, options: .atomic)
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
        // The order the markup offers formats in. Anything written that the plan does not
        // mention — the fallback, or a format from a run whose settings have since
        // changed — sorts after, keeping the fallback last where the markup needs it.
        let preferred = settings.webExport?.formats.map { plan in
            FormatPlan.sorted(plan.alternatives).compactMap(\.format.preferredExtension)
        } ?? []

        return order.map { source in
            let sorted = (bySource[source] ?? []).sorted { $0.width < $1.width }
            var entry = Entry(
                source: source,
                slug: OutputNaming.slug(source.deletingPathExtension().lastPathComponent),
                formats: groupByFormat(sorted, preferred: preferred)
            )
            // From the fallback, because the placeholder is decoded by this app and shown
            // by every browser — the format chosen for compatibility is the right source.
            if sidecars.placeholder == .base64DataURI,
               let smallest = entry.formats.last?.renditions.first {
                entry.placeholder = placeholderDataURI(for: smallest, width: sidecars.placeholderWidth)
            }
            return entry
        }
    }

    /// Splits one source's renditions by format, ordered by the plan.
    static func groupByFormat(_ renditions: [Rendition], preferred: [String]) -> [Entry.FormatGroup] {
        var order: [String] = []
        var byFormat: [String: [Rendition]] = [:]
        for rendition in renditions {
            let key = rendition.format
            if byFormat[key] == nil { order.append(key) }
            byFormat[key, default: []].append(rendition)
        }
        let ranked = order.sorted { left, right in
            let leftRank = preferred.firstIndex(of: left) ?? preferred.count
            let rightRank = preferred.firstIndex(of: right) ?? preferred.count
            guard leftRank == rightRank else { return leftRank < rightRank }
            return (order.firstIndex(of: left) ?? 0) < (order.firstIndex(of: right) ?? 0)
        }
        return ranked.map { Entry.FormatGroup(fileExtension: $0, renditions: byFormat[$0] ?? []) }
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

    /// Emits an `<img>` with a `srcset`, wrapped in a `<picture>` when the run wrote
    /// alternative formats.
    ///
    /// A `<picture>` only earns its wrapper once there is something to choose between;
    /// with one format its `<source>` list would be empty and the markup would be
    /// strictly worse than a bare `<img>`.
    ///
    /// `isHero` marks the one image a page should load first. Everything else defers.
    static func markup(
        for entry: Entry,
        settings: ResizeSettings,
        sidecars: Sidecars,
        isHero: Bool = false
    ) -> String {
        let image = imageElement(for: entry, settings: settings, sidecars: sidecars, isHero: isHero)
        guard !image.isEmpty else { return "" }

        let alternatives = entry.formats.dropLast().compactMap { group in
            sourceElement(for: group, sidecars: sidecars)
        }
        guard !alternatives.isEmpty else { return image }
        // Indented as blocks so the nested markup reads as nested once pasted.
        let blocks = (alternatives + [image])
            .map { $0.replacingOccurrences(of: "\n", with: "\n  ") }
        return "<picture>\n  " + blocks.joined(separator: "\n  ") + "\n</picture>"
    }

    /// One `<source>`: a whole format's ladder, offered ahead of the fallback.
    ///
    /// `nil` when the format has no media type to advertise, since a `<source>` without
    /// one tells the browser nothing it can act on.
    static func sourceElement(for group: Entry.FormatGroup, sidecars: Sidecars) -> String? {
        guard let type = OutputType.mimeType(forExtension: group.fileExtension),
              !group.renditions.isEmpty else { return nil }
        return """
            <source type="\(type)"
                    srcset="\(escape(srcset(group.renditions, sidecars: sidecars)))"
                    sizes="\(escape(sidecars.resolvedSizes))">
            """
    }

    static func srcset(_ renditions: [Rendition], sidecars: Sidecars) -> String {
        renditions
            .map { "\(path(for: $0, sidecars: sidecars)) \($0.width)w" }
            .joined(separator: ", ")
    }

    /// The `<img>` every browser understands, built from the fallback format alone — a
    /// srcset spanning formats would offer a browser files it may not be able to decode.
    static func imageElement(
        for entry: Entry,
        settings: ResizeSettings,
        sidecars: Sidecars,
        isHero: Bool
    ) -> String {
        guard let group = entry.formats.last, let fallback = group.renditions.last else { return "" }
        let srcset = srcset(group.renditions, sidecars: sidecars)

        var attributes = [
            "src=\"\(escape(path(for: fallback, sidecars: sidecars)))\"",
            "srcset=\"\(escape(srcset))\"",
            "sizes=\"\(escape(sidecars.resolvedSizes))\"",
            "width=\"\(fallback.width)\"",
            "height=\"\(fallback.height)\"",
            "alt=\"\(escape(altText(for: entry, settings: settings)))\""
        ]
        // Deferring the image a page paints largest delays the paint it is measured on,
        // so the hero asks to be fetched early and everything below the fold waits.
        attributes += isHero
            ? ["fetchpriority=\"high\"", "loading=\"eager\""]
            : ["loading=\"lazy\""]
        attributes.append("decoding=\"async\"")
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

    // MARK: - Structured data

    /// A `<script type="application/ld+json">` block describing the exported images.
    ///
    /// The same facts already go into IPTC and XMP, and both carriers are read — but a
    /// file's own metadata does not survive every CMS that re-encodes on upload, whereas
    /// markup pasted into a page does. Returns `nil` when no image had anything to say.
    static func structuredData(
        for entries: [Entry],
        settings: ResizeSettings,
        sidecars: Sidecars
    ) -> String? {
        let objects = entries.compactMap { imageObject(for: $0, settings: settings, sidecars: sidecars) }
        guard !objects.isEmpty else { return nil }
        // A single image is emitted as one object rather than a one-element array. Both
        // are valid; the object is what every example of this markup looks like.
        let payload: Any = objects.count == 1 ? objects[0] : objects
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let json = String(data: data, encoding: .utf8) else { return nil }
        return "<script type=\"application/ld+json\">\n\(json)\n</script>"
    }

    /// One `ImageObject`, or `nil` when the only things known about the image are its URL
    /// and its size — a block saying that describes nothing the page did not already say.
    static func imageObject(
        for entry: Entry,
        settings: ResizeSettings,
        sidecars: Sidecars
    ) -> [String: Any]? {
        guard let fallback = entry.fallback else { return nil }
        var object: [String: Any] = [
            "@context": "https://schema.org",
            "@type": "ImageObject",
            "contentUrl": path(for: fallback, sidecars: sidecars),
            "width": fallback.width,
            "height": fallback.height
        ]

        var describes = false
        func assign(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            object[key] = value
            describes = true
        }

        let rights = settings.webExport?.rights
        let name = rights.flatMap { RightsWriter.resolve($0.titlePolicy, source: entry.source, humanise: true) }
        assign("name", name)
        // Alt text falls back to the title when there is no suggestion, and a caption
        // repeating the name describes nothing — so it is only worth saying once.
        let caption = altText(for: entry, settings: settings)
        assign("caption", caption == name ? nil : caption)
        assign("creditText", rights?.credit)
        assign("copyrightNotice", rights?.copyrightNotice)
        // The two Google reads for a licensable image: the terms, and where to buy.
        assign("license", rights?.webStatementURL)
        assign("acquireLicensePage", rights?.licensorURL)
        if let rights, let creator = rights.creator, !creator.isEmpty {
            object["creator"] = ["@type": rights.creatorType.schemaType, "name": creator]
            describes = true
        }
        return describes ? object : nil
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
