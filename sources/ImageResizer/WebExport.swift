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

    init(
        schemaVersion: Int = WebExport.currentSchemaVersion,
        isEnabled: Bool = false,
        naming: Naming? = nil,
        ladder: Ladder? = nil,
        color: ColorPolicy? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.isEnabled = isEnabled
        self.naming = naming
        self.ladder = ladder
        self.color = color
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
