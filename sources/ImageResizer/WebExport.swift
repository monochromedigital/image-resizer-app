import Foundation

/// Configuration for web- and SEO-ready output.
///
/// Each of the web export features attaches here as its own optional sub-tree, so a
/// feature can ship without touching the others. A missing sub-tree means that feature
/// contributes nothing to the export. See `docs/web-export-preset.md`.
struct WebExport: Codable, Equatable {
    /// Bumped only when a change to this tree cannot be expressed as another optional
    /// field. Recorded so a future build can tell an old blob from a new one instead of
    /// guessing.
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var isEnabled: Bool
    var naming: Naming?
    var ladder: Ladder?
    var color: ColorPolicy?
    var rights: RightsMetadata?
    var sidecars: Sidecars?
    var altText: AltText?

    init(
        schemaVersion: Int = WebExport.currentSchemaVersion,
        isEnabled: Bool = false,
        naming: Naming? = nil,
        ladder: Ladder? = nil,
        color: ColorPolicy? = nil,
        rights: RightsMetadata? = nil,
        sidecars: Sidecars? = nil,
        altText: AltText? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.isEnabled = isEnabled
        self.naming = naming
        self.ladder = ladder
        self.color = color
        self.rights = rights
        self.sidecars = sidecars
        self.altText = altText
    }

    /// Decoding is deliberately lenient. A blob written by an earlier build is missing
    /// every key added since, and `SettingsStore` discards a blob that fails to decode —
    /// so a strict decoder would silently reset the user's configuration on upgrade.
    /// Absent keys fall back to their defaults instead.
    ///
    /// The synthesised decoder cannot do this: it ignores property default values for
    /// non-optional fields and throws `keyNotFound`. Removing this initialiser makes the
    /// missing-keys check in `Checks/main.swift` fail.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Self.currentSchemaVersion
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        naming = try container.decodeIfPresent(Naming.self, forKey: .naming)
        ladder = try container.decodeIfPresent(Ladder.self, forKey: .ladder)
        color = try container.decodeIfPresent(ColorPolicy.self, forKey: .color)
        rights = try container.decodeIfPresent(RightsMetadata.self, forKey: .rights)
        sidecars = try container.decodeIfPresent(Sidecars.self, forKey: .sidecars)
        altText = try container.decodeIfPresent(AltText.self, forKey: .altText)
    }
}

/// On-device alt-text suggestions.
///
/// See `AltTextGenerator` for why this is two stages rather than one model.
struct AltText: Codable, Equatable {
    enum Engine: String, Codable {
        /// Vision labels only, joined into a phrase. Works on every supported system.
        case labelsOnly
        /// Vision labels phrased by the on-device language model where one exists,
        /// falling back to `labelsOnly` where it does not.
        case automatic
    }

    var isEnabled: Bool
    var engine: Engine
    /// The floor that stops the feature guessing. A classifier given something it does
    /// not recognise still returns its best guesses, and describing an image wrongly is
    /// worse for a screen-reader user than not describing it.
    var minimumConfidence: Double
    var maximumLabels: Int
    var maxLength: Int

    init(
        isEnabled: Bool = false,
        engine: Engine = .automatic,
        minimumConfidence: Double = 0.3,
        maximumLabels: Int = 5,
        maxLength: Int = 125
    ) {
        self.isEnabled = isEnabled
        self.engine = engine
        self.minimumConfidence = minimumConfidence
        self.maximumLabels = maximumLabels
        self.maxLength = maxLength
    }

    /// Lenient for the same reason `WebExport`'s is — see the note there.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AltText()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        engine = try container.decodeIfPresent(Engine.self, forKey: .engine) ?? defaults.engine
        minimumConfidence = try container.decodeIfPresent(Double.self, forKey: .minimumConfidence)
            ?? defaults.minimumConfidence
        maximumLabels = try container.decodeIfPresent(Int.self, forKey: .maximumLabels) ?? defaults.maximumLabels
        maxLength = try container.decodeIfPresent(Int.self, forKey: .maxLength) ?? defaults.maxLength
    }
}

/// Files written alongside the images, describing the output set.
///
/// These need every final filename, which is why naming moved to plan time — the
/// manifest describes the whole batch and cannot be assembled from names invented
/// during encoding.
struct Sidecars: Codable, Equatable {
    enum PlaceholderMode: String, Codable {
        case none
        /// A tiny inline JPEG, base64 encoded, to show while the real image loads.
        case base64DataURI
    }

    var manifest: Bool
    var markupSnippet: Bool
    var placeholder: PlaceholderMode
    var placeholderWidth: Int
    /// Emitted verbatim into the `sizes` attribute; the browser needs it to pick a
    /// rendition before layout.
    var sizesAttribute: String
    /// Prepended to every path in the manifest and markup, so the output describes where
    /// the files will live rather than where they were written.
    var pathPrefix: String
    /// Whether the first image of a run is marked up as the one to load first.
    ///
    /// Batch order is the only granularity available — the sidebar lists sources and a
    /// source can be a folder — so this asks the user to drop the hero first rather than
    /// offering a per-image choice that the source list cannot express.
    var prioritiseFirstImage: Bool

    init(
        manifest: Bool = true,
        markupSnippet: Bool = true,
        placeholder: PlaceholderMode = .none,
        placeholderWidth: Int = 20,
        sizesAttribute: String = "100vw",
        pathPrefix: String = "",
        prioritiseFirstImage: Bool = true
    ) {
        self.manifest = manifest
        self.markupSnippet = markupSnippet
        self.placeholder = placeholder
        self.placeholderWidth = placeholderWidth
        self.sizesAttribute = sizesAttribute
        self.pathPrefix = pathPrefix
        self.prioritiseFirstImage = prioritiseFirstImage
    }

    var writesAnything: Bool { manifest || markupSnippet }

    /// Lenient for the same reason `WebExport`'s is — see the note there.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Sidecars()
        manifest = try container.decodeIfPresent(Bool.self, forKey: .manifest) ?? defaults.manifest
        markupSnippet = try container.decodeIfPresent(Bool.self, forKey: .markupSnippet) ?? defaults.markupSnippet
        placeholder = try container.decodeIfPresent(PlaceholderMode.self, forKey: .placeholder) ?? defaults.placeholder
        placeholderWidth = try container.decodeIfPresent(Int.self, forKey: .placeholderWidth) ?? defaults.placeholderWidth
        sizesAttribute = try container.decodeIfPresent(String.self, forKey: .sizesAttribute) ?? defaults.sizesAttribute
        pathPrefix = try container.decodeIfPresent(String.self, forKey: .pathPrefix) ?? defaults.pathPrefix
        prioritiseFirstImage = try container.decodeIfPresent(Bool.self, forKey: .prioritiseFirstImage)
            ?? defaults.prioritiseFirstImage
    }
}

/// Ownership and licensing written into every exported file.
///
/// Split by what can sensibly be batch-constant. Creator, copyright, credit and the two
/// licensing URLs describe you and are the same for every image in a run, so they live
/// in the preset. Title and description describe one photograph each — storing their
/// text in a preset would stamp the same caption onto forty different pictures, which is
/// worse for search than leaving them empty — so the preset carries only a policy.
struct RightsMetadata: Codable, Equatable {
    enum TextPolicy: String, Codable, CaseIterable {
        /// Leave whatever the source already carries.
        case keepExisting
        /// Derive from the filename, which is worth something once slugs are clean.
        case fromFilename
        /// Use the on-device suggestion, falling back to nothing when there is none.
        case fromAltText
        /// Write nothing, and remove anything inherited.
        case empty
    }

    var creator: String?
    var copyrightNotice: String?
    var credit: String?
    /// A page describing your terms. Stored and written as text; never fetched.
    var webStatementURL: String?
    /// Where the image can be licensed. Also never fetched.
    var licensorURL: String?
    var titlePolicy: TextPolicy
    var descriptionPolicy: TextPolicy

    init(
        creator: String? = nil,
        copyrightNotice: String? = nil,
        credit: String? = nil,
        webStatementURL: String? = nil,
        licensorURL: String? = nil,
        titlePolicy: TextPolicy = .keepExisting,
        descriptionPolicy: TextPolicy = .keepExisting
    ) {
        self.creator = creator
        self.copyrightNotice = copyrightNotice
        self.credit = credit
        self.webStatementURL = webStatementURL
        self.licensorURL = licensorURL
        self.titlePolicy = titlePolicy
        self.descriptionPolicy = descriptionPolicy
    }

    /// Whether anything would actually be written. An empty tree should not push the
    /// engine onto its metadata-writing path for nothing.
    var hasContent: Bool {
        [creator, copyrightNotice, credit, webStatementURL, licensorURL]
            .contains { $0?.isEmpty == false }
            || titlePolicy != .keepExisting
            || descriptionPolicy != .keepExisting
    }

    /// Lenient for the same reason `WebExport`'s is — see the note there.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        creator = try container.decodeIfPresent(String.self, forKey: .creator)
        copyrightNotice = try container.decodeIfPresent(String.self, forKey: .copyrightNotice)
        credit = try container.decodeIfPresent(String.self, forKey: .credit)
        webStatementURL = try container.decodeIfPresent(String.self, forKey: .webStatementURL)
        licensorURL = try container.decodeIfPresent(String.self, forKey: .licensorURL)
        titlePolicy = try container.decodeIfPresent(TextPolicy.self, forKey: .titlePolicy) ?? .keepExisting
        descriptionPolicy = try container.decodeIfPresent(TextPolicy.self, forKey: .descriptionPolicy) ?? .keepExisting
    }
}

/// How output colour is tagged.
///
/// Deliberately smaller than the original design sketched. Two of the three fields it
/// proposed cannot vary: `ResizeEngine.render` always composites into an sRGB context,
/// so conversion is unconditional, and a source profile is never valid for the converted
/// pixels, so keeping one is never correct. Modelling settings that can only hold one
/// value invites someone to change them.
struct ColorPolicy: Codable, Equatable {
    enum ProfileMode: String, Codable {
        /// No profile. Every browser treats untagged as sRGB, and it is the smaller file.
        case untagged
        /// An explicit sRGB profile, for pipelines that require one rather than assuming.
        case sRGB
    }

    var embedProfile: ProfileMode

    init(embedProfile: ProfileMode = .sRGB) {
        self.embedProfile = embedProfile
    }

    /// Lenient for the same reason `WebExport`'s is — see the note there.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        embedProfile = try container.decodeIfPresent(ProfileMode.self, forKey: .embedProfile) ?? .sRGB
    }
}

/// A width:height pair, stored as integers because 16:9 is exact and legible where
/// 1.7777777777777777 is neither.
struct AspectRatio: Codable, Equatable {
    var width: Int
    var height: Int

    var isValid: Bool { width > 0 && height > 0 }

    /// The height that pairs with `width` at this ratio.
    func height(forWidth width: Int) -> Int {
        guard isValid else { return width }
        return max(1, Int((Double(width) * Double(self.height) / Double(self.width)).rounded()))
    }
}

/// One source image rendered at several widths in a single pass.
///
/// The ladder supplies widths; the resize mode decides what each width means. See
/// `SizeLadder` for the expansion.
struct Ladder: Codable, Equatable {
    var widths: [Int]
    var includeOriginalSize: Bool
    /// Rungs wider than the source are dropped rather than clamped. Clamping would
    /// produce byte-identical files under different names, because `preventEnlargement`
    /// already caps the scale at 1.
    var skipUpscales: Bool
    /// Fill mode only. Stored rather than inferred from the live width and height, so a
    /// preset does not silently change shape when those fields are edited.
    var aspectRatio: AspectRatio?

    init(
        widths: [Int] = [400, 800, 1200, 1600],
        includeOriginalSize: Bool = false,
        skipUpscales: Bool = true,
        aspectRatio: AspectRatio? = nil
    ) {
        self.widths = widths
        self.includeOriginalSize = includeOriginalSize
        self.skipUpscales = skipUpscales
        self.aspectRatio = aspectRatio
    }

    /// Ascending, de-duplicated, positives only — so output ordering is stable and a
    /// typo cannot produce two rungs with the same name.
    var normalisedWidths: [Int] {
        Array(Set(widths.filter { $0 > 0 })).sorted()
    }

    /// Widths as typed: comma or space separated, order preserved, nonsense dropped.
    /// `normalisedWidths` does the sorting and de-duplication at the point of use, so
    /// what the field shows stays what was typed.
    static func parseWidths(_ text: String) -> [Int] {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" })
            .compactMap { Int($0) }
            .filter { $0 > 0 }
    }

    static func formatWidths(_ widths: [Int]) -> String {
        widths.map(String.init).joined(separator: ", ")
    }

    /// Lenient for the same reason `WebExport`'s is — see the note there.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Ladder()
        widths = try container.decodeIfPresent([Int].self, forKey: .widths) ?? defaults.widths
        includeOriginalSize = try container.decodeIfPresent(Bool.self, forKey: .includeOriginalSize)
            ?? defaults.includeOriginalSize
        skipUpscales = try container.decodeIfPresent(Bool.self, forKey: .skipUpscales)
            ?? defaults.skipUpscales
        aspectRatio = try container.decodeIfPresent(AspectRatio.self, forKey: .aspectRatio)
    }
}

/// How output filenames are built. See `OutputNaming` for the implementation.
struct Naming: Codable, Equatable {
    enum Style: String, Codable {
        /// The pre-web-export behaviour: keep the source stem, append the suffix.
        case keepOriginal
        /// Lowercase ASCII kebab-case, suitable for a URL.
        case slug
    }

    enum CollisionPolicy: String, Codable {
        /// Append `-2`, `-3`… in plan order.
        case numberSuffix
    }

    var style: Style
    var template: String
    var transliterate: Bool
    var stripCameraPrefixes: Bool
    var maxLength: Int?
    var collisionPolicy: CollisionPolicy

    init(
        style: Style = .slug,
        template: String = "{slug}",
        transliterate: Bool = true,
        stripCameraPrefixes: Bool = true,
        maxLength: Int? = 80,
        collisionPolicy: CollisionPolicy = .numberSuffix
    ) {
        self.style = style
        self.template = template
        self.transliterate = transliterate
        self.stripCameraPrefixes = stripCameraPrefixes
        self.maxLength = maxLength
        self.collisionPolicy = collisionPolicy
    }

    /// What the app did before web export existed, expressed in the new model so there
    /// is only one naming code path.
    static let legacy = Naming(
        style: .keepOriginal,
        template: "{original}{suffix}",
        transliterate: false,
        stripCameraPrefixes: false,
        maxLength: nil
    )

    /// Lenient for the same reason `WebExport`'s is — see the note there.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Naming()
        style = try container.decodeIfPresent(Style.self, forKey: .style) ?? defaults.style
        template = try container.decodeIfPresent(String.self, forKey: .template) ?? defaults.template
        transliterate = try container.decodeIfPresent(Bool.self, forKey: .transliterate)
            ?? defaults.transliterate
        stripCameraPrefixes = try container.decodeIfPresent(Bool.self, forKey: .stripCameraPrefixes)
            ?? defaults.stripCameraPrefixes
        maxLength = try container.decodeIfPresent(Int.self, forKey: .maxLength)
        collisionPolicy = try container.decodeIfPresent(CollisionPolicy.self, forKey: .collisionPolicy)
            ?? defaults.collisionPolicy
    }
}
