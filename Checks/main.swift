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
check(OutputNaming.slug("IMG_4821_Red_Chair") == "red-chair", "camera prefix and its frame number stripped")
check(OutputNaming.slug("IMG_4821 Café Sign") == "cafe-sign", "prefix, frame number, and accents together")
// Dropping the number must not leave nothing behind.
check(OutputNaming.slug("IMG_4821") == "img-4821", "a bare frame number keeps the prefix")
check(OutputNaming.slug("2024 Annual Report") == "2024-annual-report", "leading digits without a camera prefix are kept")
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

// Settings saved before the hero existed carry no such key, and the safer reading of
// silence is that a page does want its first image early.
guard let sparseSidecars = try? JSONDecoder().decode(Sidecars.self, from: Data("{\"manifest\":true}".utf8)) else {
    FileHandle.standardError.write(Data("FAILED: Sidecars rejects a blob with missing keys\n".utf8))
    exit(1)
}
check(sparseSidecars.prioritiseFirstImage, "a blob written before the hero existed still prioritises it")

// The sizes attribute. This is the half of a ladder that decides whether it paid off: the
// browser chooses a rendition before layout exists, so a wrong value spends the savings.
check(Sidecars(layout: .fullWidth).resolvedSizes == "100vw", "full width is the whole viewport")
check(
    Sidecars(layout: .half).resolvedSizes == "(max-width: 700px) 100vw, 50vw",
    "a half-width image is full width once the columns collapse"
)
check(
    Sidecars(layout: .thirds).resolvedSizes == "(max-width: 700px) 100vw, 33vw",
    "thirds: \(Sidecars(layout: .thirds).resolvedSizes)"
)
check(
    Sidecars(layout: .fixedWidth, layoutMaxWidth: 640).resolvedSizes
        == "(max-width: 640px) 100vw, 640px",
    "a fixed column caps at its own width"
)
// A half-typed number must not emit `0px`, which no browser can use.
check(
    Sidecars(layout: .fixedWidth, layoutMaxWidth: 0).resolvedSizes == "100vw",
    "an unset column width falls back rather than emitting zero"
)
check(
    Sidecars(layout: .custom, sizesAttribute: "(min-width: 60em) 24rem, 100vw").resolvedSizes
        == "(min-width: 60em) 24rem, 100vw",
    "custom is emitted verbatim"
)
// Settings written before layouts existed carry only the typed attribute. The old default
// means the user never chose; anything else was deliberate and must survive the upgrade.
guard let migratedDefault = try? JSONDecoder().decode(
    Sidecars.self, from: Data("{\"sizesAttribute\":\"100vw\"}".utf8)
), let migratedCustom = try? JSONDecoder().decode(
    Sidecars.self, from: Data("{\"sizesAttribute\":\"50vw\"}".utf8)
) else {
    FileHandle.standardError.write(Data("FAILED: Sidecars rejects a pre-layout blob\n".utf8))
    exit(1)
}
check(migratedDefault.layout == .fullWidth, "an untouched sizes attribute becomes a layout")
check(migratedCustom.layout == .custom, "a hand-typed sizes attribute is not overwritten")
check(migratedCustom.resolvedSizes == "50vw", "and it still emits what it emitted before")

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

// Target file size applies to any format whose quality can be traded away, not just the
// two it originally listed. HEIC was lossy and excluded from the start — that gap is
// closed here alongside AVIF.
check(OutputFormat.jpeg.supportsTargetFileSize, "jpeg supports a target size")
check(OutputFormat.webp.supportsTargetFileSize, "webp supports a target size")
check(OutputFormat.heic.supportsTargetFileSize, "heic supports a target size")
check(OutputFormat.avif.supportsTargetFileSize, "avif supports a target size")
check(!OutputFormat.png.supportsTargetFileSize, "png has no quality to trade")
check(!OutputFormat.tiff.supportsTargetFileSize, "tiff has no quality to trade")
check(!OutputFormat.gif.supportsTargetFileSize, "gif has no quality to trade")
// Keep Original cannot know its real output type until the source is opened.
check(!OutputFormat.original.supportsTargetFileSize, "keep original defers the decision")
// Every ImageIO type the engine will bisect must also be one it sets quality on.
for format in OutputFormat.allCases where format.supportsTargetFileSize && format != .webp {
    check(OutputType.isLossy(format.typeIdentifier!), "\(format.rawValue) bisects and sets quality consistently")
}

var heicTarget = settings(mode: .fit, width: 1_000)
heicTarget.format = .heic
heicTarget.targetFileSizeEnabled = true
heicTarget.targetFileSizeBytes = 512_000
check(heicTarget.isValid, "heic target settings validate")

// Ladder widths are typed as free text, so parsing has to survive whatever lands in the
// field without reordering what the user sees.
check(Ladder.parseWidths("400, 800, 1200") == [400, 800, 1200], "comma separated widths")
check(Ladder.parseWidths("400 800") == [400, 800], "space separated widths")
check(Ladder.parseWidths("800, 400") == [800, 400], "typed order is preserved")
check(Ladder.parseWidths("400, , 800,") == [400, 800], "stray separators are ignored")
check(Ladder.parseWidths("400, abc, -5, 0, 800") == [400, 800], "nonsense is dropped")
check(Ladder.parseWidths("") == [], "empty text yields no widths")
check(Ladder.formatWidths([400, 800]) == "400, 800", "widths format back to text")
// Round-tripping matters: the field is rendered from whatever was parsed.
check(Ladder.formatWidths(Ladder.parseWidths("400, 800, 1200")) == "400, 800, 1200", "widths round-trip")

// Rights metadata. Title text is derived per image, so only the policy is stored.
check(RightsWriter.humanised("IMG_4821 Café Sign") == "Cafe Sign", "filename becomes a readable title")
check(RightsWriter.humanised("red-chair") == "Red Chair", "slug becomes a readable title")
check(RightsWriter.humanised("🙂") == "🙂", "an unnameable stem is returned unchanged")
check(
    RightsWriter.resolve(.keepExisting, source: URL(fileURLWithPath: "/Photos/A Sign.jpg"), humanise: true) == nil,
    "keepExisting writes nothing"
)
check(
    RightsWriter.resolve(.empty, source: URL(fileURLWithPath: "/Photos/A Sign.jpg"), humanise: true) == nil,
    "empty writes nothing, and removal is handled by the caller"
)
check(
    RightsWriter.resolve(.fromFilename, source: URL(fileURLWithPath: "/Photos/A Sign.jpg"), humanise: true) == "A Sign",
    "fromFilename derives a title"
)

// An empty tree must not push the engine onto its metadata-writing path.
check(!RightsMetadata().hasContent, "an empty rights tree writes nothing")
check(RightsMetadata(creator: "Someone").hasContent, "a creator counts as content")
check(RightsMetadata(creator: "").hasContent == false, "a blank string is not content")
check(RightsMetadata(titlePolicy: .fromFilename).hasContent, "a policy alone counts as content")
check(RightsWriter.metadata(rights: RightsMetadata()) == nil, "no XMP without rights")
check(RightsWriter.metadata(rights: RightsMetadata(creator: "Someone")) == nil, "creator alone is IPTC, not XMP")
check(RightsWriter.metadata(rights: RightsMetadata(webStatementURL: "https://example.test")) != nil, "a web statement needs XMP")
check(RightsWriter.xmpPacket(rights: RightsMetadata(licensorURL: "https://example.test")) != nil, "a licensor produces an XMP packet")

// The format matrix. Like the ladder, it is settings-in, settings-out, so the whole
// feature is decidable here without touching an encoder. `writable` is passed explicitly
// so these do not pass or fail on whether this particular Mac can write AVIF.
private func withFormats(_ alternatives: [OutputFormat], base: OutputFormat = .jpeg) -> ResizeSettings {
    var configured = settings(mode: .fit, width: 800)
    configured.format = base
    configured.webExport = WebExport(
        isEnabled: true,
        formats: FormatPlan(alternatives: alternatives.map { FormatPlan.Entry(format: $0) })
    )
    return configured
}
let everything: [OutputFormat] = [.jpeg, .png, .webp, .avif, .heic]
check(
    FormatMatrix.expand(settings(mode: .fit, width: 800), writable: everything).count == 1,
    "no plan leaves the settings alone"
)
// Fallback last, because the markup falls through to the <img> and that has to be the
// format every browser can read.
check(
    FormatMatrix.expand(withFormats([.webp, .avif]), writable: everything).map(\.format)
        == [.avif, .webp, .jpeg],
    "alternatives come first, most efficient first, fallback last"
)
// A format this Mac cannot write must drop out of the plan rather than fail at encode
// time — the whole point of probing ImageIO instead of testing an OS version.
check(
    FormatMatrix.expand(withFormats([.webp, .avif]), writable: [.jpeg, .webp]).map(\.format)
        == [.webp, .jpeg],
    "an unwritable alternative is dropped"
)
check(
    FormatMatrix.expand(withFormats([.jpeg, .webp]), writable: everything).map(\.format)
        == [.webp, .jpeg],
    "an alternative repeating the fallback is dropped"
)
check(
    FormatMatrix.expand(withFormats([.original, .webp]), writable: everything).map(\.format)
        == [.webp, .jpeg],
    "keep original is not an alternative to anything"
)
// A size limit is met by trading quality away, which PNG cannot do. Carrying the flag
// onto it would make a correctly configured run invalid.
var limitedFormats = withFormats([.png, .webp])
limitedFormats.targetFileSizeEnabled = true
limitedFormats.targetFileSizeBytes = 200_000
let limited = FormatMatrix.expand(limitedFormats, writable: everything)
check(limited.allSatisfy(\.isValid), "every derived rung is runnable")
check(
    limited.first { $0.format == .png }?.targetFileSizeEnabled == false,
    "a lossless alternative drops the size limit"
)
check(
    limited.first { $0.format == .webp }?.targetFileSizeEnabled == true,
    "a lossy alternative keeps the size limit"
)

// The link-preview crop. A share image is a different picture from a ladder rung, so the
// checks that matter are the ones keeping it out of places that describe the same picture
// at several sizes.
private func socialRendition(_ name: String, _ width: Int, _ height: Int) -> Rendition {
    Rendition(
        source: URL(fileURLWithPath: "/Photos/IMG_4821 Café Sign.jpg"),
        output: URL(fileURLWithPath: "/Out/\(name)"),
        width: width, height: height, bytes: 100, role: .social
    )
}
check(SocialImage().isValid, "the default preview size is usable")
check(!SocialImage(width: 0).isValid, "a half-typed size is not")

// Sidecar paths and markup are string assembly, so they are pinned here rather than only
// end to end.
private func rendition(_ name: String, _ width: Int, _ height: Int, _ bytes: Int = 100) -> Rendition {
    Rendition(
        source: URL(fileURLWithPath: "/Photos/IMG_4821 Café Sign.jpg"),
        output: URL(fileURLWithPath: "/Out/\(name)"),
        width: width, height: height, bytes: bytes
    )
}
check(
    SidecarWriter.path(for: rendition("a-400.jpg", 400, 225), sidecars: Sidecars()) == "a-400.jpg",
    "no prefix leaves a bare filename"
)
check(
    SidecarWriter.path(for: rendition("a-400.jpg", 400, 225), sidecars: Sidecars(pathPrefix: "/images")) == "/images/a-400.jpg",
    "a prefix without a trailing slash still joins cleanly"
)
check(
    SidecarWriter.path(for: rendition("a-400.jpg", 400, 225), sidecars: Sidecars(pathPrefix: "/images/")) == "/images/a-400.jpg",
    "a prefix with a trailing slash does not double it"
)
check(SidecarWriter.escape("a&b<c>\"d\"") == "a&amp;b&lt;c&gt;&quot;d&quot;", "attribute escaping")

var sidecarSettings = settings(mode: .fit, width: 800)
sidecarSettings.webExport = WebExport(
    isEnabled: true,
    rights: RightsMetadata(titlePolicy: .fromFilename),
    sidecars: Sidecars(pathPrefix: "/images")
)
let entries = SidecarWriter.group(
    [rendition("cafe-sign-800.jpg", 800, 450), rendition("cafe-sign-400.jpg", 400, 225)],
    settings: sidecarSettings,
    sidecars: sidecarSettings.webExport!.sidecars!
)
check(entries.count == 1, "renditions group by source")
// Sorted ascending, so srcset reads small to large and the fallback is the largest.
check(entries[0].renditions.map(\.width) == [400, 800], "renditions sort by width")
check(entries[0].fallback?.width == 800, "the largest rendition is the fallback")
check(entries[0].slug == "cafe-sign", "entry slug comes from the source")

let markup = SidecarWriter.markup(
    for: entries[0], settings: sidecarSettings, sidecars: sidecarSettings.webExport!.sidecars!
)
check(markup.contains("srcset=\"/images/cafe-sign-400.jpg 400w, /images/cafe-sign-800.jpg 800w\""), "srcset: \(markup)")
check(markup.contains("src=\"/images/cafe-sign-800.jpg\""), "src falls back to the largest")
check(markup.contains("width=\"800\"") && markup.contains("height=\"450\""), "intrinsic size prevents layout shift")
check(markup.contains("alt=\"Cafe Sign\""), "alt comes from the title policy: \(markup)")
check(markup.contains("loading=\"lazy\""), "lazy loading")
check(!markup.contains("fetchpriority"), "an ordinary image asks for no priority")

// The hero is the image most likely to decide the page's largest paint. Deferring it is
// the failure this markup exists to avoid, so the two attributes are pinned together.
let heroMarkup = SidecarWriter.markup(
    for: entries[0], settings: sidecarSettings, sidecars: sidecarSettings.webExport!.sidecars!, isHero: true
)
check(heroMarkup.contains("fetchpriority=\"high\""), "the hero asks to be fetched early: \(heroMarkup)")
check(heroMarkup.contains("loading=\"eager\""), "the hero is not deferred")
check(!heroMarkup.contains("loading=\"lazy\""), "the hero is never lazy")

// Structured data. The fields are the ones a search engine reads for a licensable image,
// and they are parsed back rather than string-matched so a malformed block fails here.
var licensedSettings = sidecarSettings
licensedSettings.webExport?.rights = RightsMetadata(
    creator: "Monochrome Digital",
    creatorType: .organization,
    copyrightNotice: "© 2026 Monochrome Digital",
    credit: "Photo: Monochrome Digital",
    webStatementURL: "https://example.test/licence",
    licensorURL: "https://example.test/buy",
    titlePolicy: .fromFilename
)
let sidecarDefaults = Sidecars(pathPrefix: "/images")
guard let block = SidecarWriter.structuredData(
    for: entries, settings: licensedSettings, sidecars: sidecarDefaults
) else {
    FileHandle.standardError.write(Data("FAILED: rights produced no structured data\n".utf8))
    exit(1)
}
check(block.hasPrefix("<script type=\"application/ld+json\">"), "structured data is a script block")
guard let openBrace = block.firstIndex(of: "{"), let closeBrace = block.lastIndex(of: "}"),
      let parsed = try? JSONSerialization.jsonObject(
          with: Data(block[openBrace...closeBrace].utf8)
      ) as? [String: Any] else {
    FileHandle.standardError.write(Data("FAILED: structured data is not valid JSON\n".utf8))
    exit(1)
}
check((parsed["@type"] as? String) == "ImageObject", "structured data types the image")
check((parsed["contentUrl"] as? String) == "/images/cafe-sign-800.jpg", "contentUrl is the largest rendition")
check((parsed["width"] as? Int) == 800 && (parsed["height"] as? Int) == 450, "structured data carries dimensions")
check((parsed["license"] as? String) == "https://example.test/licence", "the licence page is the licence")
check((parsed["acquireLicensePage"] as? String) == "https://example.test/buy", "the licensing page is where to buy")
check((parsed["copyrightNotice"] as? String) == "© 2026 Monochrome Digital", "copyright carries over")
check((parsed["creditText"] as? String) == "Photo: Monochrome Digital", "credit carries over")
check((parsed["name"] as? String) == "Cafe Sign", "the title policy names the image")
// Alt text falls back to the title, and saying the same words twice under two keys
// describes nothing extra.
check(parsed["caption"] == nil, "a caption identical to the name is not repeated")
// A name alone cannot say whether a creator is a person or a company, so the choice is
// carried rather than guessed.
check(
    ((parsed["creator"] as? [String: Any])?["@type"] as? String) == "Organization",
    "the creator type is the one that was chosen"
)
check(
    ((parsed["creator"] as? [String: Any])?["name"] as? String) == "Monochrome Digital",
    "the creator is named"
)
// Without a title policy there is nothing to say, and an empty alt is a valid
// declaration that an image is decorative — a guess would be worse.
var noRights = sidecarSettings
noRights.webExport?.rights = nil
check(
    SidecarWriter.markup(for: entries[0], settings: noRights, sidecars: Sidecars()).contains("alt=\"\""),
    "no title policy yields an empty alt"
)
// The same absence in structured data: an ImageObject carrying only a URL and a size
// says nothing the markup did not, so none is emitted rather than an empty one.
check(
    SidecarWriter.structuredData(for: entries, settings: noRights, sidecars: sidecarDefaults) == nil,
    "no rights and no alt text yields no structured data"
)

// <picture>. One source written in two formats: the alternative is offered as a <source>
// and the fallback stays the <img>, so a browser understanding neither still gets a file.
var pictureSettings = sidecarSettings
pictureSettings.webExport?.formats = FormatPlan(alternatives: [FormatPlan.Entry(format: .webp)])
let pictureEntries = SidecarWriter.group(
    [
        rendition("cafe-sign-800.webp", 800, 450), rendition("cafe-sign-400.webp", 400, 225),
        rendition("cafe-sign-800.jpg", 800, 450), rendition("cafe-sign-400.jpg", 400, 225)
    ],
    settings: pictureSettings,
    sidecars: sidecarDefaults
)
check(pictureEntries.count == 1, "several formats of one source stay one entry")
check(
    pictureEntries[0].formats.map(\.fileExtension) == ["webp", "jpg"],
    "the fallback format sorts last: \(pictureEntries[0].formats.map(\.fileExtension))"
)
check(pictureEntries[0].renditions.count == 4, "the manifest still sees every rendition")
let picture = SidecarWriter.markup(
    for: pictureEntries[0], settings: pictureSettings, sidecars: sidecarDefaults
)
check(
    picture.hasPrefix("<picture>") && picture.hasSuffix("</picture>"),
    "alternatives earn the wrapper: \(picture)"
)
check(picture.contains("<source type=\"image/webp\""), "the alternative advertises its media type")
// Both elements have to agree: a <source> and the <img> describing different widths would
// have the browser pick against one layout and lay out against another.
let laidOut = SidecarWriter.markup(
    for: pictureEntries[0],
    settings: pictureSettings,
    sidecars: Sidecars(layout: .thirds, pathPrefix: "/images")
)
check(
    laidOut.components(separatedBy: "sizes=\"(max-width: 700px) 100vw, 33vw\"").count == 3,
    "the layout reaches both the source and the img: \(laidOut)"
)
check(
    picture.contains("srcset=\"/images/cafe-sign-400.webp 400w, /images/cafe-sign-800.webp 800w\""),
    "the source lists its own ladder: \(picture)"
)
// A browser reaches the <img> precisely because it could not decode the alternatives, so
// offering it one of them there would hand it the file it just refused.
check(
    picture.contains("srcset=\"/images/cafe-sign-400.jpg 400w, /images/cafe-sign-800.jpg 800w\""),
    "the img srcset is the fallback format alone: \(picture)"
)
check(picture.contains("src=\"/images/cafe-sign-800.jpg\""), "the img src is the fallback format")
// Structured data describes one canonical file, and it has to be the readable one.
guard let pictureBlock = SidecarWriter.structuredData(
    for: pictureEntries, settings: licensedSettings, sidecars: sidecarDefaults
), let pictureOpen = pictureBlock.firstIndex(of: "{"), let pictureClose = pictureBlock.lastIndex(of: "}"),
   let pictureParsed = try? JSONSerialization.jsonObject(
       with: Data(pictureBlock[pictureOpen...pictureClose].utf8)
   ) as? [String: Any] else {
    FileHandle.standardError.write(Data("FAILED: no structured data for a multi-format entry\n".utf8))
    exit(1)
}
check(
    (pictureParsed["contentUrl"] as? String) == "/images/cafe-sign-800.jpg",
    "structured data points at the fallback format"
)
// A share image alongside the ladder: it must reach the meta tags and nothing else.
var shareSettings = sidecarSettings
shareSettings.webExport?.social = SocialImage()
let shareEntries = SidecarWriter.group(
    [
        rendition("cafe-sign-400.jpg", 400, 225), rendition("cafe-sign-800.jpg", 800, 450),
        socialRendition("cafe-sign-social.jpg", 1_200, 630)
    ],
    settings: shareSettings,
    sidecars: sidecarDefaults
)
check(shareEntries[0].socialImage?.width == 1_200, "the share image is kept aside")
// The failure this guards against: a 1200-wide crop offered as a 1200-wide photograph.
check(
    shareEntries[0].renditions.allSatisfy { $0.role == .responsive },
    "the share image is not a rendition of the same picture"
)
let shareMarkup = SidecarWriter.markup(
    for: shareEntries[0], settings: shareSettings, sidecars: sidecarDefaults
)
check(!shareMarkup.contains("cafe-sign-social"), "the share image never reaches a srcset: \(shareMarkup)")
check(
    shareEntries[0].fallback?.width == 800,
    "the largest responsive rendition is still the fallback"
)
guard let tags = SidecarWriter.socialTags(for: shareEntries[0], sidecars: sidecarDefaults) else {
    FileHandle.standardError.write(Data("FAILED: no meta tags for a share image\n".utf8))
    exit(1)
}
check(
    tags.contains("<meta property=\"og:image\" content=\"/images/cafe-sign-social.jpg\">"),
    "og:image points at the crop: \(tags)"
)
check(tags.contains("<meta property=\"og:image:width\" content=\"1200\">"), "og:image:width")
check(tags.contains("<meta property=\"og:image:height\" content=\"630\">"), "og:image:height")
check(tags.contains("summary_large_image"), "the card is the large one")
check(
    SidecarWriter.socialTags(for: entries[0], sidecars: sidecarDefaults) == nil,
    "no share image, no tags"
)
// Structured data describes the photograph, and the crop is not it.
check(
    (try? JSONSerialization.jsonObject(with: Data({
        let block = SidecarWriter.structuredData(
            for: shareEntries, settings: licensedSettings, sidecars: sidecarDefaults
        ) ?? ""
        guard let open = block.firstIndex(of: "{"), let close = block.lastIndex(of: "}") else { return "" }
        return String(block[open...close])
    }().utf8)) as? [String: Any])?["contentUrl"] as? String == "/images/cafe-sign-800.jpg",
    "structured data ignores the share image"
)

// One format is not a choice, so the wrapper is not earned.
check(
    SidecarWriter.markup(for: entries[0], settings: sidecarSettings, sidecars: sidecarDefaults)
        .hasPrefix("<img "),
    "a single format stays a bare img"
)

// Alt text. The model-facing parts need a model, but the tidying that guards against its
// output is pure — and it is what stops a refusal or an over-long reply reaching a file.
check(AltTextGenerator.tidy("Wooden chair indoors.", maxLength: 125) == "Wooden chair indoors", "a trailing stop is dropped")
check(AltTextGenerator.tidy("  Drink with straw  ", maxLength: 125) == "Drink with straw", "surrounding space is trimmed")
check(AltTextGenerator.tidy("\"Sunset beach\"", maxLength: 125) == "Sunset beach", "quotes the model added are stripped")
check(AltTextGenerator.tidy("UNKNOWN", maxLength: 125) == nil, "the refusal token yields no alt text")
check(AltTextGenerator.tidy("unknown", maxLength: 125) == nil, "the refusal token is matched case-insensitively")
check(AltTextGenerator.tidy("", maxLength: 125) == nil, "empty yields no alt text")
check(AltTextGenerator.tidy("...", maxLength: 125) == nil, "punctuation alone yields no alt text")
// Truncation stops at a word boundary, so alt text never ends mid-word.
check(AltTextGenerator.tidy("a wooden chair beside a white wall", maxLength: 16) == "a wooden chair", "truncates on a word boundary")
check(AltTextGenerator.phrase(from: ["chair", "indoor"]) == "chair, indoor", "labels join into a phrase")

// A suggestion is a description; a title is a name. The description wins for alt text.
check(
    RightsWriter.resolve(.fromAltText, source: URL(fileURLWithPath: "/a/b.jpg"), humanise: true, altText: "A wooden chair") == "A wooden chair",
    "fromAltText uses the suggestion"
)
// Declining is not an instruction to erase what the source already carried.
check(
    RightsWriter.resolve(.fromAltText, source: URL(fileURLWithPath: "/a/b.jpg"), humanise: true, altText: nil) == nil,
    "no suggestion leaves the field alone"
)

// Every policy the model can hold must be reachable, or a value set elsewhere renders
// as a blank picker. This caught fromAltText being absent from the UI entirely.
check(
    Set(RightsMetadata.TextPolicy.allCases) == [.keepExisting, .fromFilename, .fromAltText, .empty],
    "the policy cases are the four the UI offers"
)

print("All Image Resizer checks passed.")
