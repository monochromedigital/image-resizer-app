import Foundation
import CoreGraphics

enum ResizeMode: String, CaseIterable, Identifiable, Codable {
    case fit = "Fit"
    case fill = "Fill & Crop"
    case longEdge = "Long Edge"
    case percentage = "Percentage"

    var id: String { rawValue }
}

enum OutputFormat: String, CaseIterable, Identifiable, Codable {
    case original = "Keep Original"
    case jpeg = "JPEG"
    case png = "PNG"
    case heic = "HEIC"
    case tiff = "TIFF"
    case gif = "GIF"
    case webp = "WebP"

    var id: String { rawValue }

    var preferredExtension: String? {
        switch self {
        case .original: nil
        case .jpeg: "jpg"
        case .png: "png"
        case .heic: "heic"
        case .tiff: "tiff"
        case .gif: "gif"
        case .webp: "webp"
        }
    }

    var typeIdentifier: CFString? {
        switch self {
        case .original: nil
        case .jpeg: "public.jpeg" as CFString
        case .png: "public.png" as CFString
        case .heic: "public.heic" as CFString
        case .tiff: "public.tiff" as CFString
        case .gif: "com.compuserve.gif" as CFString
        case .webp: "org.webmproject.webp" as CFString
        }
    }
}

struct ResizeSettings: Equatable {
    var mode: ResizeMode
    var width: Int?
    var height: Int?
    var longEdge: Int?
    var percentage: Int?
    var preventEnlargement: Bool
    var filenameSuffix: String
    var format: OutputFormat
    var quality: Double
    var preserveMetadata: Bool
    var removeLocation: Bool
    var backgroundRed: Double
    var backgroundGreen: Double
    var backgroundBlue: Double
    var useCustomDestination: Bool
    var customDestination: URL?

    var isValid: Bool {
        switch mode {
        case .fit: (width ?? 0) > 0 || (height ?? 0) > 0
        case .fill: (width ?? 0) > 0 && (height ?? 0) > 0
        case .longEdge: (longEdge ?? 0) > 0
        case .percentage: (percentage ?? 0) > 0
        }
    }
}

struct ResizePreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var width: Int?
    var height: Int?

    init(id: UUID = UUID(), name: String, width: Int?, height: Int?) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
    }
}

struct BatchProgress: Equatable {
    var completed = 0
    var skipped = 0
    var failed = 0
    var total = 0
    var currentName = ""

    var processed: Int { completed + skipped + failed }
    var fraction: Double { total == 0 ? 0 : Double(processed) / Double(total) }
}

struct BatchResult {
    let progress: BatchProgress
    let outputDirectories: [URL]
    let errors: [String]
}

struct ResizeLayout: Equatable {
    let outputSize: CGSize
    let drawRect: CGRect
}

enum ResizeMath {
    static func fittedSize(
        source: CGSize,
        width: Int?,
        height: Int?,
        preventEnlargement: Bool = false
    ) -> CGSize {
        guard source.width > 0, source.height > 0 else { return .zero }
        let widthScale = width.map { CGFloat($0) / source.width }
        let heightScale = height.map { CGFloat($0) / source.height }

        let scale: CGFloat
        switch (widthScale, heightScale) {
        case let (.some(w), .some(h)): scale = min(w, h)
        case let (.some(w), .none): scale = w
        case let (.none, .some(h)): scale = h
        case (.none, .none): scale = 1
        }

        let outputScale = preventEnlargement ? min(scale, 1) : scale
        return CGSize(
            width: max(1, (source.width * outputScale).rounded()),
            height: max(1, (source.height * outputScale).rounded())
        )
    }

    static func layout(source: CGSize, settings: ResizeSettings) -> ResizeLayout {
        guard source.width > 0, source.height > 0 else {
            return ResizeLayout(outputSize: .zero, drawRect: .zero)
        }

        switch settings.mode {
        case .fit:
            let output = fittedSize(
                source: source,
                width: settings.width,
                height: settings.height,
                preventEnlargement: settings.preventEnlargement
            )
            return ResizeLayout(outputSize: output, drawRect: CGRect(origin: .zero, size: output))

        case .fill:
            guard let width = settings.width, let height = settings.height, width > 0, height > 0 else {
                return ResizeLayout(outputSize: .zero, drawRect: .zero)
            }
            let requested = CGSize(width: width, height: height)
            let fillScale = max(requested.width / source.width, requested.height / source.height)
            let scale = settings.preventEnlargement ? min(fillScale, 1) : fillScale
            let outputRatio = fillScale > 0 ? scale / fillScale : 1
            let output = roundedSize(CGSize(
                width: requested.width * outputRatio,
                height: requested.height * outputRatio
            ))
            let drawn = CGSize(width: source.width * scale, height: source.height * scale)
            let origin = CGPoint(
                x: (output.width - drawn.width) / 2,
                y: (output.height - drawn.height) / 2
            )
            return ResizeLayout(outputSize: output, drawRect: CGRect(origin: origin, size: drawn))

        case .longEdge:
            guard let requested = settings.longEdge, requested > 0 else {
                return ResizeLayout(outputSize: .zero, drawRect: .zero)
            }
            let proposedScale = CGFloat(requested) / max(source.width, source.height)
            return proportionalLayout(source: source, proposedScale: proposedScale, preventEnlargement: settings.preventEnlargement)

        case .percentage:
            guard let percentage = settings.percentage, percentage > 0 else {
                return ResizeLayout(outputSize: .zero, drawRect: .zero)
            }
            return proportionalLayout(
                source: source,
                proposedScale: CGFloat(percentage) / 100,
                preventEnlargement: settings.preventEnlargement
            )
        }
    }

    private static func proportionalLayout(
        source: CGSize,
        proposedScale: CGFloat,
        preventEnlargement: Bool
    ) -> ResizeLayout {
        let scale = preventEnlargement ? min(proposedScale, 1) : proposedScale
        let output = roundedSize(CGSize(width: source.width * scale, height: source.height * scale))
        return ResizeLayout(outputSize: output, drawRect: CGRect(origin: .zero, size: output))
    }

    private static func roundedSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(1, size.width.rounded()), height: max(1, size.height.rounded()))
    }
}

struct ResizeJob {
    let source: URL
    let destination: URL

    func requestedOutputURL(extension outputExtension: String, filenameSuffix: String) -> URL {
        let safeSuffix = filenameSuffix.unicodeScalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == ":" {
                return "-"
            }
            return String(scalar)
        }.joined()
        let directory = destination.deletingLastPathComponent()
        let stem = destination.deletingPathExtension().lastPathComponent
        return directory
            .appendingPathComponent(stem + safeSuffix)
            .appendingPathExtension(outputExtension)
    }
}
