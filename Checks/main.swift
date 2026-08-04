import Foundation
import CoreGraphics

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
        exit(1)
    }
}

private func settings(
    mode: ResizeMode,
    width: Int? = nil,
    height: Int? = nil,
    longEdge: Int? = nil,
    percentage: Int? = nil,
    preventEnlargement: Bool = false
) -> ResizeSettings {
    ResizeSettings(
        mode: mode,
        width: width,
        height: height,
        longEdge: longEdge,
        percentage: percentage,
        preventEnlargement: preventEnlargement,
        filenameSuffix: "-resized",
        format: .jpeg,
        quality: 0.9,
        targetFileSizeEnabled: false,
        targetFileSizeBytes: nil,
        preserveMetadata: true,
        removeLocation: true,
        backgroundRed: 1,
        backgroundGreen: 1,
        backgroundBlue: 1,
        useCustomDestination: false,
        customDestination: nil
    )
}

check(
    ResizeMath.fittedSize(source: CGSize(width: 4000, height: 2000), width: 2000, height: 2000)
        == CGSize(width: 2000, height: 1000),
    "landscape bounding box"
)
check(
    ResizeMath.fittedSize(source: CGSize(width: 1000, height: 2000), width: 2000, height: 2000)
        == CGSize(width: 1000, height: 2000),
    "portrait bounding box"
)
check(
    ResizeMath.fittedSize(
        source: CGSize(width: 500, height: 250),
        width: 2000,
        height: 2000,
        preventEnlargement: true
    )
        == CGSize(width: 500, height: 250),
    "prevent upscaling"
)
check(
    ResizeMath.fittedSize(
        source: CGSize(width: 500, height: 250),
        width: 2000,
        height: 2000,
        preventEnlargement: false
    )
        == CGSize(width: 2000, height: 1000),
    "allow upscaling"
)
check(
    ResizeMath.fittedSize(source: CGSize(width: 400, height: 200), width: nil, height: 100)
        == CGSize(width: 200, height: 100),
    "single dimension"
)
check(
    ResizeMath.layout(
        source: CGSize(width: 4000, height: 2000),
        settings: settings(mode: .fill, width: 1000, height: 1000)
    ) == ResizeLayout(
        outputSize: CGSize(width: 1000, height: 1000),
        drawRect: CGRect(x: -500, y: 0, width: 2000, height: 1000)
    ),
    "fill and center crop"
)
check(
    ResizeMath.layout(
        source: CGSize(width: 4000, height: 2000),
        settings: settings(mode: .longEdge, longEdge: 1000)
    ).outputSize == CGSize(width: 1000, height: 500),
    "long edge"
)
check(
    ResizeMath.layout(
        source: CGSize(width: 4000, height: 2000),
        settings: settings(mode: .percentage, percentage: 50)
    ).outputSize == CGSize(width: 2000, height: 1000),
    "percentage"
)
check(
    ResizeMath.layout(
        source: CGSize(width: 500, height: 250),
        settings: settings(mode: .percentage, percentage: 200, preventEnlargement: true)
    ).outputSize == CGSize(width: 500, height: 250),
    "percentage respects no-enlargement"
)
check(
    JobPlanner.relativePath(
        of: URL(fileURLWithPath: "/Photos/Trips/Paris/image.jpg"),
        beneath: URL(fileURLWithPath: "/Photos")
    ) == "Trips/Paris/image.jpg",
    "folder structure"
)
// The pre-web-export naming behaviour, now expressed through Naming.legacy. These three
// assertions are unchanged from before the refactor and are what pins it down.
private func legacyStem(_ name: String, suffix: String) -> String {
    OutputNaming.stem(
        source: URL(fileURLWithPath: "/Photos/\(name)"),
        naming: .legacy,
        filenameSuffix: suffix,
        outputExtension: "jpg"
    )
}
check(legacyStem("image.png", suffix: "-resized") == "image-resized", "filename suffix")
check(legacyStem("image.png", suffix: "") == "image", "blank filename suffix")
check(legacyStem("image.png", suffix: "/web:\n") == "image-web--", "safe filename suffix")

// Slugging.
check(OutputNaming.slug("Red Chair.jpg") == "red-chair-jpg", "spaces become hyphens")
check(OutputNaming.slug("Café Münster") == "cafe-munster", "accents transliterate")
check(OutputNaming.slug("الكرسي الأحمر") == "alkrsy-alahmr", "arabic transliterates")
check(OutputNaming.slug("红色椅子") == "hong-se-yi-zi", "han transliterates to pinyin")
check(OutputNaming.slug("IMG_4821_Red_Chair") == "4821-red-chair", "camera prefix stripped")
check(OutputNaming.slug("DSCF0001") == "dscf0001", "prefix kept when nothing nameable remains")
check(OutputNaming.slug("  --Hello---World--  ") == "hello-world", "separator runs collapse")
check(OutputNaming.slug("Ünïcôdé", transliterate: false) == "n-c-d", "transliteration can be off")
check(OutputNaming.slug("a-very-long-name", maxLength: 6) == "a-very", "truncation trims trailing separators")

// A stem can never be empty, or the output would be a bare extension.
check(!OutputNaming.stem(
    source: URL(fileURLWithPath: "/Photos/🙂🙂.png"),
    naming: Naming(),
    filenameSuffix: "",
    outputExtension: "jpg"
).isEmpty, "unnameable source still produces a stem")

// Unknown tokens are dropped rather than left literal, and the leftover separator goes
// with them. {width} arrives with the size ladder.
check(
    OutputNaming.expand("{slug}-{width}", values: ["slug": "chair"]) == "chair-",
    "unknown token removed"
)
check(
    OutputNaming.stem(
        source: URL(fileURLWithPath: "/Photos/Red Chair.png"),
        naming: Naming(template: "{slug}-{width}"),
        filenameSuffix: "",
        outputExtension: "jpg"
    ) == "red-chair",
    "trailing separator from an empty token is tidied away"
)

// Output type resolution has to match between JobPlanner and ResizeEngine, or files get
// an extension that misdescribes their contents.
check(
    OutputType.resolve(sourceType: nil, isRaw: true, format: .original) == OutputFormat.jpeg.typeIdentifier,
    "camera RAW keeping its original format falls back to JPEG"
)
check(
    OutputType.resolve(
        sourceType: "public.png" as CFString,
        isRaw: false,
        format: .original
    ) == "public.png" as CFString,
    "keep original preserves a writable source type"
)
check(
    OutputType.fileExtension(for: "public.jpeg" as CFString, fallback: "cr3") == "jpg",
    "jpeg extension"
)
check(
    OutputType.fileExtension(for: "com.apple.something" as CFString, fallback: "CR3") == "cr3",
    "unknown type falls back to the lowercased source extension"
)
check(
    OutputType.usesWebPCodec(sourceType: "org.webmproject.webp" as CFString, format: .original),
    "keeping the original format of a WebP routes to the WebP encoder"
)
check(FileSizeUnit.kilobytes.bytes(for: 500) == 512_000, "kilobyte target")
check(FileSizeUnit.megabytes.bytes(for: 2) == 2_097_152, "megabyte target")
check(FileSizeUnit.kilobytes.bytes(for: 0) == nil, "invalid target")
var targetSettings = settings(mode: .fit, width: 1_000)
targetSettings.targetFileSizeEnabled = true
targetSettings.targetFileSizeBytes = 512_000
check(targetSettings.isValid, "JPEG target settings")
targetSettings.format = .png
check(!targetSettings.isValid, "unsupported target format")
targetSettings.format = .webp
targetSettings.targetFileSizeBytes = nil
check(!targetSettings.isValid, "missing target size")

// Presets saved by builds that predate web export must keep loading. SettingsStore
// discards a preset blob that fails to decode, so a regression here silently wipes
// every preset the user has saved.
let legacyPresetJSON = Data("""
[{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","name":"4K","width":3840,"height":2160}]
""".utf8)
guard let legacyPresets = try? JSONDecoder().decode([ResizePreset].self, from: legacyPresetJSON),
      let legacyPreset = legacyPresets.first else {
    FileHandle.standardError.write(Data("FAILED: legacy preset JSON no longer decodes\n".utf8))
    exit(1)
}
check(legacyPreset.name == "4K", "legacy preset name")
check(legacyPreset.width == 3840 && legacyPreset.height == 2160, "legacy preset dimensions")
check(
    legacyPreset.mode == nil && legacyPreset.format == nil && legacyPreset.quality == nil
        && legacyPreset.preventEnlargement == nil && legacyPreset.webExport == nil,
    "legacy preset asserts nothing it never knew about"
)

var fullPreset = ResizePreset(name: "Web Export", width: 1_600, height: nil)
fullPreset.mode = .fit
fullPreset.format = .webp
fullPreset.quality = 0.82
fullPreset.preventEnlargement = true
fullPreset.preserveMetadata = true
fullPreset.removeLocation = true
fullPreset.webExport = WebExport(isEnabled: true)
guard let encodedPreset = try? JSONEncoder().encode(fullPreset),
      let roundTrippedPreset = try? JSONDecoder().decode(ResizePreset.self, from: encodedPreset) else {
    FileHandle.standardError.write(Data("FAILED: preset round-trip threw\n".utf8))
    exit(1)
}
check(roundTrippedPreset == fullPreset, "preset round-trip")

// A blob written before a field was added is missing that key. Decoding has to fall
// back to defaults rather than throw, because SettingsStore drops what it cannot read.
guard let sparseWebExport = try? JSONDecoder().decode(WebExport.self, from: Data("{}".utf8)) else {
    FileHandle.standardError.write(Data("FAILED: WebExport rejects a blob with missing keys\n".utf8))
    exit(1)
}
check(sparseWebExport.schemaVersion == WebExport.currentSchemaVersion, "web export schema fallback")
check(!sparseWebExport.isEnabled, "web export defaults to off")

// The size ladder. A rung is just ResizeSettings with different numbers, which is what
// keeps ResizeMath, the render path and the encoders out of this feature entirely.
private func laddered(
    _ mode: ResizeMode,
    widths: [Int],
    sourceWidth: Double?,
    sourceHeight: Double = 1_000,
    skipUpscales: Bool = true,
    includeOriginalSize: Bool = false,
    aspectRatio: AspectRatio? = nil,
    liveWidth: Int? = nil,
    liveHeight: Int? = nil
) -> [ResizeSettings] {
    var value = settings(mode: mode, width: liveWidth, height: liveHeight)
    value.webExport = WebExport(
        isEnabled: true,
        ladder: Ladder(
            widths: widths,
            includeOriginalSize: includeOriginalSize,
            skipUpscales: skipUpscales,
            aspectRatio: aspectRatio
        )
    )
    return SizeLadder.expand(value, sourceSize: sourceWidth.map { CGSize(width: $0, height: sourceHeight) })
}

check(
    laddered(.fit, widths: [400, 800, 1200], sourceWidth: 4_000).map(\.width) == [400, 800, 1200],
    "fit ladder constrains width per rung"
)
check(
    laddered(.fit, widths: [400, 800], sourceWidth: 4_000).allSatisfy { $0.height == nil },
    "fit rungs leave height unconstrained so proportions follow the source"
)
check(
    laddered(.longEdge, widths: [400, 800], sourceWidth: 4_000).map(\.longEdge) == [400, 800],
    "long edge ladder sets the long edge per rung"
)
check(
    laddered(.fill, widths: [400, 800], sourceWidth: 4_000, aspectRatio: AspectRatio(width: 16, height: 9))
        .map { [$0.width, $0.height] } == [[400, 225], [800, 450]],
    "fill ladder crops every rung to the stored ratio"
)
check(
    laddered(.fill, widths: [400], sourceWidth: 4_000, liveWidth: 1_600, liveHeight: 1_600)
        .map { [$0.width, $0.height] } == [[400, 400]],
    "fill ladder falls back to the live width and height when no ratio is stored"
)

// Rungs wider than the source are dropped, not clamped: preventEnlargement would cap
// them all at the source width and emit byte-identical files under different names.
check(
    laddered(.fit, widths: [400, 800, 1200, 1600], sourceWidth: 900).map(\.width) == [400, 800],
    "upscaling rungs are dropped"
)
check(
    laddered(.fit, widths: [400, 800], sourceWidth: 900, skipUpscales: false).map(\.width) == [400, 800],
    "dropping can be switched off"
)
// An image narrower than every breakpoint must still produce a file rather than
// vanishing from the batch without an error.
check(
    laddered(.fit, widths: [400, 800, 1200], sourceWidth: 320).map(\.width) == [320],
    "a source below every rung falls back to its own width"
)
check(
    laddered(.fit, widths: [400, 800], sourceWidth: 1_000, includeOriginalSize: true).map(\.width)
        == [400, 800, 1_000],
    "the original size can be added as a rung"
)
check(
    laddered(.fit, widths: [800, 400, 800, -5, 0], sourceWidth: 4_000).map(\.width) == [400, 800],
    "widths are sorted, de-duplicated, and stripped of nonsense"
)

// Percentage scales by a factor of the source, so there is no fixed width to ladder.
check(!SizeLadder.applies(to: .percentage), "percentage mode has no ladder")
check(
    laddered(.percentage, widths: [400, 800], sourceWidth: 4_000).count == 1,
    "percentage mode yields a single unchanged pass"
)
// Without a ladder the expansion has to be a no-op, so callers never branch on it.
check(
    SizeLadder.expand(settings(mode: .fit, width: 2_000), sourceSize: CGSize(width: 4_000, height: 2_000)).count == 1,
    "no ladder means one pass"
)
// Unknown source dimensions must not drop anything — the rungs are all we know.
check(
    laddered(.fit, widths: [400, 800], sourceWidth: nil).map(\.width) == [400, 800],
    "an unreadable source size keeps every rung"
)

check(AspectRatio(width: 16, height: 9).height(forWidth: 1_600) == 900, "ratio height")
check(AspectRatio(width: 0, height: 9).height(forWidth: 800) == 800, "a nonsense ratio is ignored")

// {width} and {height} name the file after the size it is actually written at.
check(
    OutputNaming.stem(
        source: URL(fileURLWithPath: "/Photos/Red Chair.png"),
        naming: Naming(template: "{slug}-{width}"),
        filenameSuffix: "",
        outputExtension: "jpg",
        outputSize: CGSize(width: 800, height: 450)
    ) == "red-chair-800",
    "width token"
)
check(
    OutputNaming.stem(
        source: URL(fileURLWithPath: "/Photos/Red Chair.png"),
        naming: Naming(template: "{slug}-{width}x{height}"),
        filenameSuffix: "",
        outputExtension: "jpg",
        outputSize: CGSize(width: 800, height: 450)
    ) == "red-chair-800x450",
    "width and height tokens"
)

// AVIF. Whether this machine can write it is a runtime fact, not an OS-version one, so
// the format list is derived from ImageIO rather than gated on #available.
check(OutputType.fileExtension(for: "public.avif" as CFString, fallback: "png") == "avif", "avif extension")
check(OutputFormat.avif.preferredExtension == "avif", "avif preferred extension")
check(OutputFormat.avif.typeIdentifier as String? == "public.avif", "avif type identifier")
check(OutputType.isLossy("public.avif" as CFString), "avif is lossy")
check(OutputType.isLossy("public.heic" as CFString), "heic is lossy")
check(!OutputType.isLossy("public.png" as CFString), "png is not lossy")
check(OutputFormat.writable.contains(.original), "keep original is always offered")
// ImageIO cannot write WebP — the bundled encoder does — so it must survive the filter.
check(OutputFormat.writable.contains(.webp), "webp survives the ImageIO filter")
check(OutputFormat.writable.allSatisfy { OutputFormat.allCases.contains($0) }, "writable is a subset")
if OutputFormat.writable.contains(.avif) {
    print("AVIF is writable on this machine.")
} else {
    print("AVIF is not writable on this machine; the format picker will omit it.")
}

print("All Image Resizer checks passed.")
