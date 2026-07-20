import Foundation
import CoreGraphics

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
    var width: Int?
    var height: Int?
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
        (width ?? 0) > 0 || (height ?? 0) > 0
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

enum ResizeMath {
    static func fittedSize(source: CGSize, width: Int?, height: Int?) -> CGSize {
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

        return CGSize(
            width: max(1, (source.width * scale).rounded()),
            height: max(1, (source.height * scale).rounded())
        )
    }
}

struct ResizeJob {
    let source: URL
    let destination: URL
}
