import Foundation
import CoreGraphics
import ImageIO
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Suggests alt text for an image, entirely on this Mac.
///
/// Two stages, because no single on-device model does both halves. Vision recognises
/// what is in the picture but only produces labels. Apple's on-device language model
/// writes fluent text but **cannot see images at all** — its `Prompt` accepts strings
/// only. So Vision looks and the language model phrases, and when the language model is
/// unavailable the labels are joined into a plain phrase instead.
///
/// Nothing here reaches the network in either stage.
enum AltTextGenerator {
    /// Alt text per source. Sources that yield nothing confident are absent from the
    /// result rather than present with an empty string — an absent description and a
    /// deliberately blank one mean different things downstream.
    static func generate(for sources: [URL], settings: AltText) async -> [URL: String] {
        guard settings.isEnabled else { return [:] }
        var result: [URL: String] = [:]
        for source in sources {
            guard let image = thumbnail(for: source) else { continue }
            let found = labels(
                for: image,
                minimumConfidence: settings.minimumConfidence,
                limit: settings.maximumLabels
            )
            guard !found.isEmpty else { continue }
            if let text = await describe(found, settings: settings) {
                result[source] = text
            }
        }
        return result
    }

    /// Classification does not need full resolution, and decoding a 60-megapixel raw for
    /// it would dominate the run.
    static func thumbnail(for source: URL, maxPixelSize: Int = 640) -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary)
    }

    /// What Vision is confident enough to name.
    ///
    /// The confidence floor is what stops the feature inventing things. A photograph of
    /// something the classifier does not recognise produces low-confidence guesses, and
    /// describing an image wrongly is worse for a screen-reader user than not describing
    /// it at all.
    static func labels(for image: CGImage, minimumConfidence: Double, limit: Int) -> [String] {
        let request = VNClassifyImageRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return []
        }
        return (request.results ?? [])
            .filter { Double($0.confidence) >= minimumConfidence }
            .prefix(max(1, limit))
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    }

    static func describe(_ labels: [String], settings: AltText) async -> String? {
        #if canImport(FoundationModels)
        if settings.engine == .automatic, #available(macOS 26, *),
           let sentence = await LanguageModelPhrasing.sentence(
               prompt: prompt(labels: labels, context: settings.context),
               maxLength: settings.maxLength
           ) {
            return sentence
        }
        #endif
        // The labels path cannot use the context: there is no model to fold it in, and
        // appending it to a list of labels produces "chair, indoor, Beirut café" — which
        // reads as another thing the recogniser saw.
        return tidy(phrase(from: labels), maxLength: settings.maxLength)
    }

    /// What the phrasing stage is told.
    ///
    /// Pure string assembly, deliberately: what the model is given — and what it is not —
    /// is the whole safety story of this feature, so it belongs where it can be checked
    /// rather than inside an availability-gated type that the checks cannot reach.
    ///
    /// The context is labelled as the author's assertion about the batch rather than as
    /// something observed, because the model must not treat it as another detection.
    static func prompt(labels: [String], context: String) -> String {
        let base = "Labels: \(labels.joined(separator: ", "))"
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        // Capped so a pasted paragraph cannot crowd out the labels, which are the only
        // part of the prompt that describes this particular image.
        let capped = trimmed.count > 120 ? String(trimmed.prefix(120)) : trimmed
        return base + "\nThe author says this about every image in the batch: \(capped)"
    }

    /// The fallback when no language model is available: the labels themselves, most
    /// confident first. Blunt, but never wrong about what was detected.
    static func phrase(from labels: [String]) -> String {
        labels.joined(separator: ", ")
    }

    /// Trims, caps, and rejects the model's own refusal token.
    ///
    /// A trailing full stop is stripped because alt text is a phrase, not a sentence, and
    /// screen readers pause on the punctuation. Truncation happens at a word boundary so
    /// the result never ends mid-word.
    static func tidy(_ text: String, maxLength: Int) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !value.isEmpty, value.uppercased() != "UNKNOWN" else { return nil }
        while value.hasSuffix(".") { value.removeLast() }
        guard maxLength > 0, value.count > maxLength else {
            return value.isEmpty ? nil : value
        }
        var truncated = String(value.prefix(maxLength))
        if let lastSpace = truncated.lastIndex(of: " ") { truncated = String(truncated[..<lastSpace]) }
        truncated = truncated.trimmingCharacters(in: CharacterSet(charactersIn: " ,;-"))
        return truncated.isEmpty ? nil : truncated
    }
}

#if canImport(FoundationModels)
/// Turns labels into a readable phrase using the on-device language model.
///
/// Isolated behind `@available` so nothing here is referenced on a system that has no
/// such model. The framework is weak-linked; see `Package.swift`.
@available(macOS 26, *)
enum LanguageModelPhrasing {
    /// Deliberately restrictive. An earlier, friendlier prompt turned the labels
    /// `liquid, drink, straw_drinking` into "A woman drinking a popsicle from a straw" —
    /// inventing a person who was in neither the image nor the labels. Alt text that
    /// confidently describes something absent is worse than no alt text, so the
    /// instructions forbid introducing anything and provide an explicit way to decline.
    private static let instructions = """
    You convert object labels into alt text for a web image.
    Rules, in order of importance:
    1. Use ONLY the given labels and, if one is provided, the author's statement about \
    the batch. Never introduce a person, object, action, colour, or setting that is in \
    neither.
    2. The author's statement is context, not a description of this image. It may narrow \
    or name what the labels already describe. It must never replace them: if it mentions \
    something the labels do not, leave that thing out.
    3. If the labels are too vague to describe anything, reply with exactly: UNKNOWN — \
    even when an author statement is present.
    4. One short noun phrase. No sentence-ending period. Keep it brief.
    5. No preamble, no quotes, no explanation.
    """

    static func sentence(prompt: String, maxLength: Int) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        do {
            let session = LanguageModelSession(instructions: instructions)
            // Low temperature: this is a rewriting task, not a creative one.
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(temperature: 0.2)
            )
            return AltTextGenerator.tidy(response.content, maxLength: maxLength)
        } catch {
            // Any failure falls through to the label phrase rather than failing the run.
            return nil
        }
    }
}
#endif
