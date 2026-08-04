import Foundation
import CoreGraphics

/// Builds output filenames from a source URL and a `Naming` configuration.
///
/// Pure string math — no filesystem access, so it stays in the unit-check compile unit.
/// Collision resolution lives in `NameReservations`, which does touch the filesystem.
enum OutputNaming {
    /// Prefixes cameras and phones prepend to otherwise meaningless filenames.
    /// Matched case-insensitively, longest first so `_DSC` wins over `_D`.
    private static let cameraPrefixes = [
        "DSCF", "DSCN", "GOPR", "IMG_", "IMG-", "DSC_", "DSC-", "_MG_", "_DSC", "PXL_", "DJI_"
    ]

    /// Reduces a filename stem to lowercase ASCII kebab-case.
    static func slug(
        _ value: String,
        transliterate: Bool = true,
        stripCameraPrefixes: Bool = true,
        maxLength: Int? = nil
    ) -> String {
        var working = value
        if stripCameraPrefixes { working = strippingCameraPrefix(working) }
        if transliterate { working = transliterated(working) }

        var result = ""
        var pendingSeparator = false
        for scalar in working.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingSeparator, !result.isEmpty { result.append("-") }
                pendingSeparator = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingSeparator = true
            }
        }
        return truncated(result, to: maxLength)
    }

    /// Substitutes `{token}` placeholders. Tokens absent from `values` are removed
    /// rather than left literal — a filename containing `{width}` is worse than one
    /// missing that component.
    static func expand(_ template: String, values: [String: String]) -> String {
        var result = template
        for (name, value) in values {
            result = result.replacingOccurrences(of: "{\(name)}", with: value)
        }
        while let open = result.firstIndex(of: "{"),
              let close = result[open...].firstIndex(of: "}") {
            result.removeSubrange(open...close)
        }
        return result
    }

    /// The legacy suffix sanitiser: characters that would break a path component become
    /// hyphens, one for one. Deliberately not collapsed — `-web--` is the documented
    /// result for a suffix of `/web:\n`.
    static func sanitisedSuffix(_ suffix: String) -> String {
        suffix.unicodeScalars.map { scalar in
            if CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == ":" {
                return "-"
            }
            return String(scalar)
        }.joined()
    }

    /// The filename stem for one output, before the extension and before collision
    /// resolution.
    static func stem(
        source: URL,
        naming: Naming,
        filenameSuffix: String,
        outputExtension: String,
        outputSize: CGSize? = nil
    ) -> String {
        let original = source.deletingPathExtension().lastPathComponent
        let suffix = sanitisedSuffix(filenameSuffix)
        var dimensions: [String: String] = [:]
        if let outputSize, outputSize.width > 0, outputSize.height > 0 {
            dimensions["width"] = String(Int(outputSize.width.rounded()))
            dimensions["height"] = String(Int(outputSize.height.rounded()))
        }

        switch naming.style {
        case .keepOriginal:
            // Must stay byte-identical to the pre-web-export behaviour, so the result is
            // returned untidied — the suffix may legitimately contain runs of hyphens.
            let expanded = expand(naming.template, values: dimensions.merging([
                "original": original,
                "suffix": suffix,
                "format": outputExtension
            ]) { _, explicit in explicit })
            return expanded.isEmpty ? original : expanded

        case .slug:
            let slugged = slug(
                original,
                transliterate: naming.transliterate,
                stripCameraPrefixes: naming.stripCameraPrefixes
            )
            let expanded = expand(naming.template, values: dimensions.merging([
                "slug": slugged,
                "original": original,
                "suffix": suffix,
                "format": outputExtension
            ]) { _, explicit in explicit })
            return fallback(for: tidied(expanded, maxLength: naming.maxLength), original: original)
        }
    }

    /// Collapses separator runs left behind by empty tokens and trims the edges.
    private static func tidied(_ value: String, maxLength: Int?) -> String {
        var result = ""
        var pendingSeparator = false
        for character in value {
            if character == "-" || character == "_" || character == " " {
                pendingSeparator = true
            } else {
                if pendingSeparator, !result.isEmpty { result.append("-") }
                pendingSeparator = false
                result.append(character)
            }
        }
        return truncated(result, to: maxLength)
    }

    /// A stem must never be empty, or the output is a bare extension. Most scripts
    /// romanise — Han becomes pinyin, Arabic becomes Latin — but a name made entirely of
    /// emoji or punctuation reduces to nothing, so fall back through progressively
    /// weaker options rather than writing `.jpg`.
    private static func fallback(for value: String, original: String) -> String {
        if !value.isEmpty { return value }
        let untruncated = slug(original, transliterate: true, stripCameraPrefixes: false)
        return untruncated.isEmpty ? "image" : untruncated
    }

    private static func truncated(_ value: String, to maxLength: Int?) -> String {
        guard let maxLength, maxLength > 0, value.count > maxLength else { return value }
        var result = String(value.prefix(maxLength))
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }

    private static func transliterated(_ value: String) -> String {
        let latin = value.applyingTransform(.toLatin, reverse: false) ?? value
        return latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
    }

    /// Strips a camera prefix only when something nameable survives. `IMG_4821` would
    /// otherwise become `4821`, which is a worse filename than `img-4821`.
    ///
    /// The prefix and its frame number are treated as one unit, so
    /// `IMG_4821 Café Sign` becomes `cafe-sign` rather than `4821-cafe-sign` — the file
    /// describes a café sign, not image 4821. The number is kept only when dropping it
    /// would leave nothing nameable behind.
    private static func strippingCameraPrefix(_ value: String) -> String {
        let upper = value.uppercased()
        for prefix in cameraPrefixes where upper.hasPrefix(prefix) {
            let stripped = String(value.dropFirst(prefix.count))
            guard stripped.contains(where: \.isLetter) else { return value }
            let withoutFrameNumber = stripped.drop(while: \.isNumber)
            return withoutFrameNumber.contains(where: \.isLetter)
                ? String(withoutFrameNumber)
                : stripped
        }
        return value
    }
}

/// Hands out output URLs that do not collide, either with each other or with files
/// already on disk.
///
/// Slugging makes collisions ordinary rather than rare — `IMG_1234.jpg`, `img 1234.png`
/// and `IMG-1234.jpeg` all reduce to the same stem — so uniqueness has to be decided
/// once, for the whole batch, before anything is written.
final class NameReservations {
    private var taken: Set<String> = []

    init() {}

    func reserve(_ requested: URL) -> URL {
        let directory = requested.deletingLastPathComponent()
        let stem = requested.deletingPathExtension().lastPathComponent
        let fileExtension = requested.pathExtension

        var candidate = requested
        var number = 2
        while isTaken(candidate) {
            candidate = directory
                .appendingPathComponent("\(stem)-\(number)")
                .appendingPathExtension(fileExtension)
            number += 1
        }
        taken.insert(key(for: candidate))
        return candidate
    }

    /// Checks the filesystem as well as this batch's reservations, so a rerun into a
    /// folder that already holds output keeps numbering upward instead of overwriting.
    private func isTaken(_ url: URL) -> Bool {
        taken.contains(key(for: url)) || FileManager.default.fileExists(atPath: url.path)
    }

    /// Case-folded, because the default macOS filesystem is case-insensitive:
    /// `Red-Chair.jpg` and `red-chair.jpg` are the same file.
    private func key(for url: URL) -> String {
        url.standardizedFileURL.path.lowercased()
    }
}
