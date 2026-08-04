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

    init(
        schemaVersion: Int = WebExport.currentSchemaVersion,
        isEnabled: Bool = false,
        naming: Naming? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.isEnabled = isEnabled
        self.naming = naming
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
