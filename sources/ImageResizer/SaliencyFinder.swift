import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Finds what a picture is *of*, so a crop can be anchored on it.
///
/// Fill mode and the link-preview crop both throw away part of the frame, and the middle
/// of a photograph is frequently not its subject — a portrait shot with headroom loses
/// the head. Vision's attention-based saliency reports where a viewer would look, which
/// is a better anchor than the geometric centre and costs one small decode per source.
///
/// On this Mac, like everything else here. No network, no model download.
enum SaliencyFinder {
    /// A focus point per source, in Vision's normalised space: origin bottom left, both
    /// axes 0…1. Sources with no confident subject are absent rather than centred, so
    /// the caller keeps the difference between "look here" and "no opinion".
    static func focusPoints(for sources: [URL]) async -> [URL: CGPoint] {
        var result: [URL: CGPoint] = [:]
        for source in sources {
            // The same thumbnail the alt-text pass uses: saliency is about composition,
            // and full resolution would only make it slower.
            guard let image = AltTextGenerator.thumbnail(for: source),
                  let focus = focus(in: image) else { continue }
            result[source] = focus
        }
        return result
    }

    static func focus(in image: CGImage) -> CGPoint? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        let observations = (request.results ?? []).compactMap { $0 as VNSaliencyImageObservation }
        return centre(ofBoxes: observations.flatMap { $0.salientObjects ?? [] }.map(\.boundingBox))
    }

    /// The middle of everything worth looking at.
    ///
    /// The union rather than the strongest single box: a photograph of two people has two
    /// salient objects, and anchoring on the more prominent one crops the other out —
    /// which is the failure this feature exists to avoid, only committed with confidence.
    static func centre(ofBoxes boxes: [CGRect]) -> CGPoint? {
        guard let first = boxes.first else { return nil }
        let union = boxes.dropFirst().reduce(first) { $0.union($1) }
        guard union.width > 0, union.height > 0 else { return nil }
        return CGPoint(x: union.midX, y: union.midY)
    }
}
