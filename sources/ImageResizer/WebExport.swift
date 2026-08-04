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

    init(schemaVersion: Int = WebExport.currentSchemaVersion, isEnabled: Bool = false) {
        self.schemaVersion = schemaVersion
        self.isEnabled = isEnabled
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
    }
}
