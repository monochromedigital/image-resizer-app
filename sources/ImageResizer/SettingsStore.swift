import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var mode: ResizeMode { didSet { save() } }
    @Published var widthText: String { didSet { save() } }
    @Published var heightText: String { didSet { save() } }
    @Published var longEdgeText: String { didSet { save() } }
    @Published var percentageText: String { didSet { save() } }
    @Published var preventEnlargement: Bool { didSet { save() } }
    @Published var format: OutputFormat { didSet { save() } }
    @Published var quality: Double { didSet { save() } }
    @Published var preserveMetadata: Bool { didSet { save() } }
    @Published var removeLocation: Bool { didSet { save() } }
    @Published var useCustomDestination: Bool { didSet { save() } }
    @Published var customDestination: URL? { didSet { save() } }
    @Published var backgroundRed: Double { didSet { save() } }
    @Published var backgroundGreen: Double { didSet { save() } }
    @Published var backgroundBlue: Double { didSet { save() } }
    @Published var presets: [ResizePreset] { didSet { savePresets() } }

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
        format = OutputFormat(rawValue: defaults.string(forKey: "format") ?? "") ?? .original
        quality = defaults.object(forKey: "quality") as? Double ?? 0.9
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
            format: format,
            quality: quality,
            preserveMetadata: preserveMetadata,
            removeLocation: removeLocation,
            backgroundRed: backgroundRed,
            backgroundGreen: backgroundGreen,
            backgroundBlue: backgroundBlue,
            useCustomDestination: useCustomDestination,
            customDestination: customDestination
        )
    }

    func apply(_ preset: ResizePreset) {
        widthText = preset.width.map(String.init) ?? ""
        heightText = preset.height.map(String.init) ?? ""
    }

    func addPreset(name: String) {
        presets.append(ResizePreset(name: name, width: positiveInt(widthText), height: positiveInt(heightText)))
    }

    func deletePresets(at offsets: IndexSet) {
        presets.remove(atOffsets: offsets)
    }

    private func positiveInt(_ value: String) -> Int? {
        guard let number = Int(value), number > 0 else { return nil }
        return number
    }

    private func save() {
        guard !isLoading else { return }
        defaults.set(mode.rawValue, forKey: "resizeMode")
        defaults.set(widthText, forKey: "width")
        defaults.set(heightText, forKey: "height")
        defaults.set(longEdgeText, forKey: "longEdge")
        defaults.set(percentageText, forKey: "percentage")
        defaults.set(preventEnlargement, forKey: "preventEnlargement")
        defaults.set(format.rawValue, forKey: "format")
        defaults.set(quality, forKey: "quality")
        defaults.set(preserveMetadata, forKey: "preserveMetadata")
        defaults.set(removeLocation, forKey: "removeLocation")
        defaults.set(useCustomDestination, forKey: "useCustomDestination")
        defaults.set(customDestination, forKey: "customDestination")
        defaults.set(backgroundRed, forKey: "backgroundRed")
        defaults.set(backgroundGreen, forKey: "backgroundGreen")
        defaults.set(backgroundBlue, forKey: "backgroundBlue")
    }

    private func savePresets() {
        guard !isLoading, let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: "presets")
    }
}
