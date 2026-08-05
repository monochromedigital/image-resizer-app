import Foundation

/// Expands one set of resize settings into one per output format.
///
/// The same trick the size ladder plays: a format is just `ResizeSettings` with a
/// different `format` in it, so the render path, the quality bisection, and both encoders
/// need no knowledge of the matrix. `JobPlanner` runs this and the ladder together, and
/// what reaches the batch loop is more jobs.
enum FormatMatrix {
    /// The settings to write `source` under, fallback last.
    ///
    /// Last because that is the order the markup wants: a browser reads `<source>`
    /// elements in turn and falls through to the `<img>`, so the format every browser can
    /// read has to be the one left at the end.
    ///
    /// Returns a single unchanged entry when no alternatives apply, so callers do not
    /// need to branch on whether the feature is switched on.
    static func expand(
        _ settings: ResizeSettings,
        writable: [OutputFormat] = OutputFormat.writable
    ) -> [ResizeSettings] {
        guard let plan = settings.webExport?.formats, !plan.alternatives.isEmpty else {
            return [settings]
        }
        let available = Set(writable)
        var seen: Set<OutputFormat> = [settings.format]
        let alternatives = FormatPlan.sorted(plan.alternatives).filter { entry in
            // "Keep Original" is not an alternative to anything — it resolves per source,
            // so it cannot be offered as a format a browser might prefer.
            guard entry.format != .original, available.contains(entry.format) else { return false }
            // A duplicate would be rendered twice into the same name and land as
            // `chair-400-2.webp`, which no markup would ever point at.
            return seen.insert(entry.format).inserted
        }
        return alternatives.map { derive(settings, entry: $0) } + [settings]
    }

    /// Whether more than one file per size will be written. Cheap enough for a label that
    /// updates as the user types, because it asks the settings rather than the disk.
    static func count(for settings: ResizeSettings, writable: [OutputFormat] = OutputFormat.writable) -> Int {
        expand(settings, writable: writable).count
    }

    private static func derive(_ settings: ResizeSettings, entry: FormatPlan.Entry) -> ResizeSettings {
        var derived = settings
        derived.format = entry.format
        if let quality = entry.quality { derived.quality = quality }
        // A size limit is met by trading quality away, which a lossless format cannot do.
        // Carrying the flag onto one would fail `isValid` for a run the user did configure
        // correctly.
        derived.targetFileSizeEnabled = settings.targetFileSizeEnabled && entry.format.supportsTargetFileSize
        return derived
    }
}
