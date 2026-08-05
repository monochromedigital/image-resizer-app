import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var mode: ResizeMode { didSet { save() } }
    @Published var widthText: String { didSet { save() } }
    @Published var heightText: String { didSet { save() } }
    @Published var longEdgeText: String { didSet { save() } }
    @Published var percentageText: String { didSet { save() } }
    @Published var preventEnlargement: Bool { didSet { save() } }
    @Published var filenameSuffix: String { didSet { save() } }
    @Published var format: OutputFormat { didSet { save() } }
    @Published var quality: Double { didSet { save() } }
    @Published var targetFileSizeEnabled: Bool { didSet { save() } }
    @Published var targetFileSizeText: String { didSet { save() } }
    @Published var targetFileSizeUnit: FileSizeUnit { didSet { save() } }
    @Published var preserveMetadata: Bool { didSet { save() } }
    @Published var removeLocation: Bool { didSet { save() } }
    @Published var useCustomDestination: Bool { didSet { save() } }
    @Published var customDestination: URL? { didSet { save() } }
    @Published var backgroundRed: Double { didSet { save() } }
    @Published var backgroundGreen: Double { didSet { save() } }
    @Published var backgroundBlue: Double { didSet { save() } }
    @Published var presets: [ResizePreset] { didSet { savePresets() } }
    @Published var webExport: WebExport { didSet { saveWebExport() } }
    /// Ladder widths are edited as text and parsed on read, matching how width, height
    /// and the other numeric fields already work — a live-parsed binding fights the user
    /// while they type.
    @Published var ladderWidthsText: String { didSet { save() } }

    private let defaults: UserDefaults
    private var isLoading = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = ResizeMode(rawValue: defaults.string(forKey: "resizeMode") ?? "") ?? .fit
        widthText = defaults.string(forKey: "width") ?? "2048"
        heightText = defaults.string(forKey: "height") ?? "2048"
        longEdgeText = defaults.string(forKey: "longEdge") ?? "2048"
        percentageText = defaults.string(forKey: "percentage") ?? "50"
        preventEnlargement = defaults.object(forKey: "preventEnlargement") as? Bool ?? true
        filenameSuffix = defaults.string(forKey: "filenameSuffix") ?? "-resized"
        let storedFormat = OutputFormat(rawValue: defaults.string(forKey: "format") ?? "") ?? .original
        // A format this Mac cannot write would leave the picker showing an empty
        // selection, so fall back rather than stranding the user on it.
        format = OutputFormat.writable.contains(storedFormat) ? storedFormat : .original
        quality = defaults.object(forKey: "quality") as? Double ?? 0.9
        targetFileSizeEnabled = defaults.bool(forKey: "targetFileSizeEnabled")
        targetFileSizeText = defaults.string(forKey: "targetFileSize") ?? "500"
        targetFileSizeUnit = FileSizeUnit(rawValue: defaults.string(forKey: "targetFileSizeUnit") ?? "") ?? .kilobytes
        preserveMetadata = defaults.object(forKey: "preserveMetadata") as? Bool ?? true
        removeLocation = defaults.object(forKey: "removeLocation") as? Bool ?? true
        useCustomDestination = defaults.bool(forKey: "useCustomDestination")
        customDestination = defaults.url(forKey: "customDestination")
        backgroundRed = defaults.object(forKey: "backgroundRed") as? Double ?? 1
        backgroundGreen = defaults.object(forKey: "backgroundGreen") as? Double ?? 1
        backgroundBlue = defaults.object(forKey: "backgroundBlue") as? Double ?? 1
        if let data = defaults.data(forKey: "presets"),
           let decoded = try? JSONDecoder().decode([ResizePreset].self, from: data) {
            presets = decoded
        } else {
            presets = [
                ResizePreset(name: "Full HD", width: 1920, height: 1080),
                ResizePreset(name: "Square 2048", width: 2048, height: 2048),
                ResizePreset(name: "4K", width: 3840, height: 2160)
            ]
        }
        ladderWidthsText = defaults.string(forKey: "ladderWidths") ?? "400, 800, 1200, 1600"
        if let data = defaults.data(forKey: "webExport"),
           let decoded = try? JSONDecoder().decode(WebExport.self, from: data) {
            webExport = decoded
        } else {
            webExport = WebExport()
        }
        isLoading = false
    }

    var settings: ResizeSettings {
        ResizeSettings(
            mode: mode,
            width: positiveInt(widthText),
            height: positiveInt(heightText),
            longEdge: positiveInt(longEdgeText),
            percentage: positiveInt(percentageText),
            preventEnlargement: preventEnlargement,
            filenameSuffix: filenameSuffix,
            format: format,
            quality: quality,
            targetFileSizeEnabled: targetFileSizeEnabled,
            targetFileSizeBytes: targetFileSizeUnit.bytes(for: positiveDouble(targetFileSizeText)),
            preserveMetadata: preserveMetadata,
            removeLocation: removeLocation,
            backgroundRed: backgroundRed,
            backgroundGreen: backgroundGreen,
            backgroundBlue: backgroundBlue,
            useCustomDestination: useCustomDestination,
            customDestination: customDestination,
            webExport: resolvedWebExport
        )
    }

    /// The live tree with the text-edited fields folded back in.
    private var resolvedWebExport: WebExport? {
        guard webExport.isEnabled else { return nil }
        var resolved = webExport
        if resolved.ladder != nil {
            resolved.ladder?.widths = Ladder.parseWidths(ladderWidthsText)
        }
        return resolved
    }

    /// Turning web export on materialises the sub-trees it implies, so the section does
    /// something the moment it is switched on. The ladder stays opt-in: it multiplies the
    /// number of files written, which should be a deliberate choice rather than a
    /// side effect of enabling the section.
    var isWebExportEnabled: Bool {
        get { webExport.isEnabled }
        set {
            var updated = webExport
            updated.isEnabled = newValue
            if newValue {
                updated.naming = updated.naming ?? Naming()
                updated.color = updated.color ?? ColorPolicy()
                updated.rights = updated.rights ?? RightsMetadata()
            }
            webExport = updated
        }
    }

    var areSidecarsEnabled: Bool {
        get { webExport.sidecars != nil }
        set {
            var updated = webExport
            updated.sidecars = newValue ? (updated.sidecars ?? Sidecars()) : nil
            webExport = updated
        }
    }

    var isLadderEnabled: Bool {
        get { webExport.ladder != nil }
        set {
            var updated = webExport
            updated.ladder = newValue ? (updated.ladder ?? Ladder()) : nil
            webExport = updated
        }
    }

    /// Assigns every field the preset asserts, leaving `nil` fields untouched.
    ///
    /// `webExport` is replaced wholesale rather than merged field by field: partially
    /// merging a nested tree produces combinations nobody configured — half of the last
    /// run's settings and half of the preset's.
    func apply(_ preset: ResizePreset) {
        if let width = preset.width { widthText = String(width) }
        if let height = preset.height { heightText = String(height) }
        if let longEdge = preset.longEdge { longEdgeText = String(longEdge) }
        if let percentage = preset.percentage { percentageText = String(percentage) }
        if let mode = preset.mode { self.mode = mode }
        if let preventEnlargement = preset.preventEnlargement { self.preventEnlargement = preventEnlargement }
        if let format = preset.format { self.format = format }
        if let quality = preset.quality { self.quality = quality }
        if let preserveMetadata = preset.preserveMetadata { self.preserveMetadata = preserveMetadata }
        if let removeLocation = preset.removeLocation { self.removeLocation = removeLocation }
        if let webExport = preset.webExport {
            self.webExport = webExport
            if let widths = webExport.ladder?.widths, !widths.isEmpty {
                ladderWidthsText = Ladder.formatWidths(widths)
            }
        }
    }

    /// Captures the whole current configuration, not just the dimensions.
    ///
    /// Saving a preset while a ladder and a naming template are configured and getting
    /// back only a width and a height would be indistinguishable from a bug.
    func addPreset(name: String) {
        var preset = ResizePreset(name: name, width: positiveInt(widthText), height: positiveInt(heightText))
        preset.mode = mode
        preset.longEdge = positiveInt(longEdgeText)
        preset.percentage = positiveInt(percentageText)
        preset.preventEnlargement = preventEnlargement
        preset.format = format
        preset.quality = quality
        preset.preserveMetadata = preserveMetadata
        preset.removeLocation = removeLocation
        preset.webExport = resolvedWebExport
        presets.append(preset)
    }

    func deletePresets(at offsets: IndexSet) {
        presets.remove(atOffsets: offsets)
    }

    private func positiveInt(_ value: String) -> Int? {
        guard let number = Int(value), number > 0 else { return nil }
        return number
    }

    private func positiveDouble(_ value: String) -> Double {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        return Double(normalized) ?? 0
    }

    private func save() {
        guard !isLoading else { return }
        defaults.set(mode.rawValue, forKey: "resizeMode")
        defaults.set(widthText, forKey: "width")
        defaults.set(heightText, forKey: "height")
        defaults.set(longEdgeText, forKey: "longEdge")
        defaults.set(percentageText, forKey: "percentage")
        defaults.set(preventEnlargement, forKey: "preventEnlargement")
        defaults.set(filenameSuffix, forKey: "filenameSuffix")
        defaults.set(format.rawValue, forKey: "format")
        defaults.set(quality, forKey: "quality")
        defaults.set(targetFileSizeEnabled, forKey: "targetFileSizeEnabled")
        defaults.set(targetFileSizeText, forKey: "targetFileSize")
        defaults.set(targetFileSizeUnit.rawValue, forKey: "targetFileSizeUnit")
        defaults.set(preserveMetadata, forKey: "preserveMetadata")
        defaults.set(removeLocation, forKey: "removeLocation")
        defaults.set(useCustomDestination, forKey: "useCustomDestination")
        defaults.set(customDestination, forKey: "customDestination")
        defaults.set(backgroundRed, forKey: "backgroundRed")
        defaults.set(backgroundGreen, forKey: "backgroundGreen")
        defaults.set(backgroundBlue, forKey: "backgroundBlue")
        defaults.set(ladderWidthsText, forKey: "ladderWidths")
    }

    private func savePresets() {
        guard !isLoading, let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: "presets")
    }

    /// Stored as one JSON blob rather than the discrete keys the flat settings use.
    /// The tree is deep enough that a key per leaf would be unmanageable, and it keeps
    /// the live value the same type as the one a preset carries.
    private func saveWebExport() {
        guard !isLoading, let data = try? JSONEncoder().encode(webExport) else { return }
        defaults.set(data, forKey: "webExport")
    }
}
