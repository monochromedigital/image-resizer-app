import Foundation
import CoreGraphics
import ImageIO

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
    case avif = "AVIF"

    var id: String { rawValue }

    /// Whether a size limit can be met by trading quality away. Spelled out rather than
    /// derived so a format added later has to be considered rather than defaulting in.
    var supportsTargetFileSize: Bool {
        switch self {
        case .jpeg, .heic, .avif, .webp: true
        // Keep Original is excluded because the real output type is not known until the
        // source is opened.
        case .original, .png, .tiff, .gif: false
        }
    }

    var preferredExtension: String? {
        switch self {
        case .original: nil
        case .jpeg: "jpg"
        case .png: "png"
        case .heic: "heic"
        case .tiff: "tiff"
        case .gif: "gif"
        case .webp: "webp"
        case .avif: "avif"
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
        case .avif: "public.avif" as CFString
        }
    }

    /// The formats this Mac can actually produce.
    ///
    /// Derived from ImageIO at launch rather than gated on an OS version. The writable
    /// set has grown across releases and the exact floor for some types is not
    /// documented, so asking is both more accurate than guessing and self-maintaining.
    /// WebP is exempt because it is written by the bundled encoder, not by ImageIO.
    static let writable: [OutputFormat] = {
        let types = Set(CGImageDestinationCopyTypeIdentifiers() as! [String])
        return allCases.filter { format in
            guard let identifier = format.typeIdentifier else { return true }
            return format == .webp || types.contains(identifier as String)
        }
    }()
}

enum FileSizeUnit: String, CaseIterable, Identifiable, Codable {
    case kilobytes = "KB"
    case megabytes = "MB"

    var id: String { rawValue }

    func bytes(for amount: Double) -> Int? {
        guard amount.isFinite, amount > 0 else { return nil }
        let multiplier = self == .kilobytes ? 1_024.0 : 1_048_576.0
        let value = amount * multiplier
        guard value <= Double(Int.max) else { return nil }
        return Int(value.rounded())
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
    var targetFileSizeEnabled: Bool
    var targetFileSizeBytes: Int?
    var preserveMetadata: Bool
    var removeLocation: Bool
    var backgroundRed: Double
    var backgroundGreen: Double
    var backgroundBlue: Double
    var useCustomDestination: Bool
    var customDestination: URL?
    /// Present only while web export is switched on; `nil` means a plain resize.
    /// Defaulted so the memberwise initialiser stays source-compatible.
    var webExport: WebExport? = nil

    /// Whether a run can start.
    ///
    /// A ladder supplies the widths itself, so the width and height fields stop being
    /// required once one is configured — otherwise a fully configured ladder leaves the
    /// Resize button disabled with a hint asking for a size it does not need. Fill is the
    /// exception: it still needs a shape to crop to, from the ladder's stored ratio or
    /// from the live fields.
    var isValid: Bool {
        let ladderWidths = webExport?.ladder?.normalisedWidths ?? []
        let hasLadder = !ladderWidths.isEmpty && SizeLadder.applies(to: mode)
        let validSize = if hasLadder {
            switch mode {
            case .fit, .longEdge: true
            case .fill: (webExport?.ladder?.aspectRatio?.isValid ?? false)
                || ((width ?? 0) > 0 && (height ?? 0) > 0)
            case .percentage: (percentage ?? 0) > 0
            }
        } else {
            switch mode {
            case .fit: (width ?? 0) > 0 || (height ?? 0) > 0
            case .fill: (width ?? 0) > 0 && (height ?? 0) > 0
            case .longEdge: (longEdge ?? 0) > 0
            case .percentage: (percentage ?? 0) > 0
            }
        }
        let validTarget = !targetFileSizeEnabled
            || (format.supportsTargetFileSize && (targetFileSizeBytes ?? 0) > 0)
        return validSize && validTarget
    }
}

/// A named set of setting overrides.
///
/// Every field is optional and `nil` means "leave the current value alone", so a preset
/// asserts only what it cares about. Presets saved before a field existed decode with
/// that field `nil` and keep behaving exactly as they did.
struct ResizePreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var width: Int?
    var height: Int?
    var mode: ResizeMode?
    var longEdge: Int?
    var percentage: Int?
    var preventEnlargement: Bool?
    var format: OutputFormat?
    var quality: Double?
    var preserveMetadata: Bool?
    var removeLocation: Bool?
    var webExport: WebExport?

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

/// One written file, recorded so the sidecars can describe the output set without
/// re-deriving anything.
struct Rendition: Equatable {
    let source: URL
    let output: URL
    let width: Int
    let height: Int
    let bytes: Int
    var altText: String? = nil

    var format: String { output.pathExtension.lowercased() }
}

struct BatchResult {
    let progress: BatchProgress
    let outputDirectories: [URL]
    let errors: [String]
    var renditions: [Rendition] = []
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

/// One source image, the exact file it will be written to, and the settings to render
/// it with.
///
/// `output` is fully resolved by `JobPlanner` — extension, naming template, and
/// collision suffix included — so nothing downstream has to invent a filename. The
/// settings travel with the job because a size ladder turns one source into several
/// jobs that differ only in their target dimensions, and because a resolved filename is
/// only correct for the settings it was derived from.
struct ResizeJob {
    let source: URL
    let output: URL
    let settings: ResizeSettings
    /// Filled in before the batch starts, when alt text is switched on. Defaulted so the
    /// planner and the checks need not supply it.
    var altText: String? = nil
}

/// Decides which container type an output is written as.
///
/// Shared by `JobPlanner`, which needs the extension to resolve names before encoding,
/// and `ResizeEngine`, which needs the type to create the destination. If these two
/// disagreed, files would be written with an extension that misdescribes their contents.
enum OutputType {
    static func resolve(sourceType: CFString?, isRaw: Bool, format: OutputFormat) -> CFString {
        guard format == .original else { return format.typeIdentifier! }
        // Camera RAW cannot be written back out, so "Keep Original" becomes JPEG.
        return (isRaw ? OutputFormat.jpeg.typeIdentifier : sourceType) ?? OutputFormat.jpeg.typeIdentifier!
    }

    static func fileExtension(for type: CFString, fallback: String) -> String {
        switch type as String {
        case "public.jpeg": "jpg"
        case "public.png": "png"
        case "public.heic": "heic"
        case "public.tiff": "tiff"
        case "com.compuserve.gif": "gif"
        case "org.webmproject.webp": "webp"
        case "public.avif": "avif"
        default: fallback.isEmpty ? "jpg" : fallback.lowercased()
        }
    }

    /// The media type a `<source>` element needs to advertise a format.
    ///
    /// Keyed by extension rather than by `OutputFormat` because the sidecars describe
    /// files that are already on disk, and "Keep Original" means the format a rendition
    /// ended up in is only knowable from its name.
    static func mimeType(forExtension fileExtension: String) -> String? {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "heic": "image/heic"
        case "tiff", "tif": "image/tiff"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "avif": "image/avif"
        default: nil
        }
    }

    /// Types that honour `kCGImageDestinationLossyCompressionQuality`. Anything else
    /// ignores the quality slider, so setting it would be misleading.
    static func isLossy(_ type: CFString) -> Bool {
        ["public.jpeg", "public.heic", "public.avif"].contains(type as String)
    }

    /// WebP is written by the bundled command-line encoder rather than ImageIO, so the
    /// engine has to route around `CGImageDestination` for it.
    static func usesWebPCodec(sourceType: CFString?, format: OutputFormat) -> Bool {
        format == .webp
            || (format == .original && sourceType as String? == OutputFormat.webp.typeIdentifier as String?)
    }
}
