import Foundation
import CoreGraphics

/// Expands one set of resize settings into one per ladder rung.
///
/// A rung is nothing more than `ResizeSettings` with different numbers in it, so the
/// ladder needs no changes to `ResizeMath`, the render path, the quality bisection, or
/// the WebP encoder. Expansion happens in `JobPlanner`, which turns each rung into its
/// own `ResizeJob`; the batch loop and progress accounting carry on counting jobs.
enum SizeLadder {
    /// The settings to render `source` at, one entry per output file.
    ///
    /// Returns a single unchanged entry when no ladder applies, so callers do not need
    /// to branch on whether web export is switched on.
    static func expand(_ settings: ResizeSettings, sourceSize: CGSize?) -> [ResizeSettings] {
        guard let ladder = settings.webExport?.ladder, applies(to: settings.mode) else {
            return [settings]
        }
        var widths = ladder.normalisedWidths
        guard !widths.isEmpty else { return [settings] }

        if let sourceSize, sourceSize.width > 0 {
            let native = Int(sourceSize.width.rounded())
            if ladder.skipUpscales {
                widths = widths.filter { $0 <= native }
                // Every rung was wider than the source. Emitting nothing would drop the
                // image from the batch silently, so fall back to its own width: an image
                // smaller than the narrowest breakpoint still has to exist on the page.
                if widths.isEmpty { widths = [native] }
            }
            if ladder.includeOriginalSize, !widths.contains(native) {
                widths.append(native)
                widths.sort()
            }
        }

        return widths.map { rung(settings, width: $0, ladder: ladder) }
    }

    /// Percentage scales by a factor of the source, which has no fixed width to ladder
    /// against — the two ideas are mutually exclusive.
    static func applies(to mode: ResizeMode) -> Bool {
        mode != .percentage
    }

    private static func rung(_ settings: ResizeSettings, width: Int, ladder: Ladder) -> ResizeSettings {
        var rung = settings
        switch settings.mode {
        case .fit:
            rung.width = width
            // Constrain the width alone; the height follows from the source proportions.
            rung.height = nil
        case .fill:
            rung.width = width
            rung.height = fillHeight(for: width, settings: settings, ladder: ladder)
        case .longEdge:
            rung.longEdge = width
        case .percentage:
            break
        }
        return rung
    }

    /// The crop height for a Fill rung. Prefers the ratio stored in the ladder and falls
    /// back to whatever the live width and height fields describe.
    private static func fillHeight(for width: Int, settings: ResizeSettings, ladder: Ladder) -> Int {
        if let ratio = ladder.aspectRatio, ratio.isValid {
            return ratio.height(forWidth: width)
        }
        guard let liveWidth = settings.width, let liveHeight = settings.height,
              liveWidth > 0, liveHeight > 0 else {
            return width
        }
        return AspectRatio(width: liveWidth, height: liveHeight).height(forWidth: width)
    }
}
