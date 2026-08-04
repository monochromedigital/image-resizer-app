# Web Export — preset data model

Status: **proposal**. No implementation has started.

Covers the data model for seven features that make Image Resizer output web- and
SEO-ready:

1. Filename slugification
2. Responsive size ladder
3. AVIF output
4. Force-sRGB on export
5. IPTC/XMP rights write-back
6. Sidecar outputs (manifest, `<picture>` snippet, LQIP)
7. On-device alt text

Everything here is offline. No feature in this document performs a network request;
URLs are stored and written as plain strings and are never fetched, resolved, or
validated against a remote host.

---

## Decisions this design rests on

| # | Decision |
|---|---|
| 1 | Web export extends the **existing** `ResizePreset` rather than sitting beside it. Every new field is optional; `nil` means "leave this setting alone." |
| 2 | The ladder **composes** with the existing resize modes — it supplies widths, the mode decides what each width means. Disabled in percentage mode. |
| 3 | Multiple output formats per run, as an **ordered** list, because that is what `<picture>` requires. |
| 4 | Rights metadata splits into **batch-constant** fields (in the preset) and **per-image** text (Title/Description, policy only in the preset). |
| 5 | Alt text uses **Vision on macOS 14** as the floor, with Foundation Models gated behind `#available(macOS 26, *)`. Deployment target stays at 14. |

---

## 1. The type

### `ResizePreset`, widened

Today a preset is `{id, name, width, height}` and `apply(_:)` assigns exactly two text
fields. It becomes a set of optional overrides:

```swift
struct ResizePreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String

    // Existing — unchanged, still optional.
    var width: Int?
    var height: Int?

    // Widened resize settings. nil = leave the current value alone.
    var mode: ResizeMode?
    var longEdge: Int?
    var percentage: Int?
    var preventEnlargement: Bool?
    var format: OutputFormat?
    var quality: Double?
    var preserveMetadata: Bool?
    var removeLocation: Bool?

    // The new subtree. nil = this preset says nothing about web export.
    var webExport: WebExport?
}
```

**Backward compatibility is free.** Swift's synthesised `Decodable` uses
`decodeIfPresent` for `Optional` properties, so existing saved JSON —
`{"id":…,"name":"4K","width":3840,"height":2160}` — decodes with every new field `nil`.
The three seeded presets keep behaving exactly as they do now. No migration code, no
version field, no data loss.

### `WebExport`

```swift
struct WebExport: Codable, Equatable {
    var schemaVersion: Int = 1
    var isEnabled: Bool = false

    var naming: Naming?           // feature 1
    var ladder: Ladder?           // feature 2
    var formats: FormatPlan?      // feature 3
    var color: ColorPolicy?       // feature 4
    var rights: RightsMetadata?   // feature 5
    var sidecars: Sidecars?       // feature 6
    var altText: AltText?         // feature 7
}
```

Each sub-struct being optional means **each feature can ship in its own PR without
touching the others**. A branch implementing slugification adds `Naming` and leaves the
other six properties absent from the type entirely until their turn.

`schemaVersion` is cheap insurance. We know this tree will grow; having the field from
day one means a future breaking change can be detected rather than guessed at.

### The seven sub-structs

```swift
// 1 — Filename slugification
struct Naming: Codable, Equatable {
    enum Style: String, Codable { case keepOriginal, slug }
    enum CollisionPolicy: String, Codable { case numberSuffix, contentHash }

    var style: Style = .slug
    var template: String = "{slug}-{width}"
    var transliterate: Bool = true          // accents, Arabic, CJK → ASCII
    var stripCameraPrefixes: Bool = true    // IMG_, DSC_, DSCF, _MG_, P10…
    var maxLength: Int? = 80
    var collisionPolicy: CollisionPolicy = .numberSuffix
}

// 2 — Responsive size ladder
struct Ladder: Codable, Equatable {
    var widths: [Int] = [400, 800, 1200, 1600]
    var includeOriginalSize: Bool = false
    var skipUpscales: Bool = true           // drop rungs wider than the source
}

// 3 — Output formats, ordered for <picture>
struct FormatPlan: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var format: OutputFormat
        var quality: Double?
        var targetFileSizeBytes: Int?
    }
    var sources: [Entry] = []               // emitted as <source>, in this order
    var fallback: Entry                     // emitted as <img>
}

// 4 — Colour
struct ColorPolicy: Codable, Equatable {
    enum ProfileMode: String, Codable { case none, sRGB }
    var convertToSRGB: Bool = true
    var embedProfile: ProfileMode = .sRGB
    var stripSourceProfile: Bool = true
}

// 5 — Rights metadata
struct RightsMetadata: Codable, Equatable {
    enum TextPolicy: String, Codable {
        case keepExisting, fromFilename, fromAltText, empty
    }
    // Batch-constant — safe to store in a preset.
    var creator: String?
    var copyrightNotice: String?
    var credit: String?
    var webStatementURL: String?            // xmpRights:WebStatement
    var licensorURL: String?                // plus:Licensor

    // Per-image — the preset stores only the policy, never the text.
    var titlePolicy: TextPolicy = .keepExisting
    var descriptionPolicy: TextPolicy = .keepExisting
}

// 6 — Sidecars
struct Sidecars: Codable, Equatable {
    enum LQIPMode: String, Codable { case none, base64DataURI }

    var manifest: Bool = true               // manifest.json
    var pictureSnippet: Bool = true         // snippet.html
    var lqip: LQIPMode = .none
    var lqipWidth: Int = 20
    var sizesAttribute: String = "100vw"
    var pathPrefix: String = ""             // URL prefix used in srcset, e.g. "/images/"
}

// 7 — Alt text
struct AltText: Codable, Equatable {
    enum Engine: String, Codable {
        case visionLabels                   // macOS 14+, returns labels
        case automatic                      // Foundation Models if available, else Vision
    }
    var isEnabled: Bool = false
    var engine: Engine = .automatic
    var maxLength: Int = 125
}
```

**Why `FormatPlan` uses an ordered list of `Entry` rather than
`[OutputFormat: Double]`:** Swift encodes a `Dictionary` whose key is neither `String`
nor `Int` as a flat **array of alternating keys and values**, which is unreadable JSON.
`OutputFormat` being `String`-backed does not change this — it would need
`CodingKeyRepresentable`. An ordered array is also semantically correct here: browsers
pick the first `<source>` they understand, so order is load-bearing, and a dictionary
would throw it away.

---

## 2. How it serialises

Presets already persist as a single JSON blob under the `"presets"` `UserDefaults` key
via `savePresets()`. That doesn't change — the blob just gets richer.

```json
[
  { "id": "…", "name": "4K", "width": 3840, "height": 2160 },

  {
    "id": "…",
    "name": "Web Export",
    "mode": "Fit",
    "width": 1600,
    "preventEnlargement": true,
    "removeLocation": true,
    "webExport": {
      "schemaVersion": 1,
      "isEnabled": true,
      "naming": {
        "style": "slug",
        "template": "{slug}-{width}",
        "transliterate": true,
        "stripCameraPrefixes": true,
        "maxLength": 80,
        "collisionPolicy": "numberSuffix"
      },
      "ladder": { "widths": [400, 800, 1200, 1600], "skipUpscales": true },
      "formats": {
        "sources": [
          { "format": "AVIF", "quality": 0.6 },
          { "format": "WebP", "quality": 0.8 }
        ],
        "fallback": { "format": "JPEG", "quality": 0.85 }
      },
      "color": { "convertToSRGB": true, "embedProfile": "sRGB" },
      "rights": {
        "creator": "Monochrome Digital",
        "copyrightNotice": "© 2026 Monochrome Digital",
        "webStatementURL": "https://monochrome.digital/licence",
        "descriptionPolicy": "fromAltText"
      },
      "sidecars": { "manifest": true, "pictureSnippet": true, "pathPrefix": "/images/" }
    }
  }
]
```

The first entry is an existing preset, untouched, still valid.

### Live (non-preset) state

`SettingsStore` currently persists ~20 **discrete** `UserDefaults` keys, one per
property. Adding ~30 more discrete keys for web export would be unpleasant to write and
worse to read.

**Recommendation:** persist the live `WebExport` as a **single JSON blob** under one new
key, `"webExport"`, exactly as `presets` already does. This mixes two persistence
styles in one class, but the precedent exists, the alternative is thirty
`defaults.set(...)` lines, and it keeps the live value and the preset value as the same
type — so applying a preset is an assignment, not a field-by-field copy.

---

## 3. How it composes with existing resize settings

### Applying a preset

`SettingsStore.apply(_:)` currently hardcodes two assignments. It becomes: **for each
non-nil field, assign; leave `nil` fields untouched.**

One deliberate exception — `webExport` **replaces wholesale** rather than merging
field-by-field. Partial merging of a nested tree produces states no one intended (half
of last run's ladder, half of the preset's). A preset either has an opinion about web
export or it doesn't.

### Reaching the pipeline

`ResizeSettings` gains one property:

```swift
struct ResizeSettings: Equatable {
    // … existing 17 properties …
    var webExport: WebExport?
}
```

`WebExport` is `Equatable`, so `ResizeSettings` stays `Equatable`. It is also `Codable`,
which `ResizeSettings` is not and does not need to be.

### Where the fan-out happens

This is the load-bearing structural decision.

`ResizeEngine.resize(job:settings:)` returns **one** `URL` for **one** `ResizeJob`, and
`progress.completed += 1` counts jobs. Rather than fight that, the ladder and format
matrix expand **in `JobPlanner`**, producing more `ResizeJob`s:

```
1 source image
  × 4 ladder rungs
  × 3 formats
  = 12 ResizeJobs, each with its own derived ResizeSettings
```

A rung is nothing more than a `ResizeSettings` with different numbers in it:

```swift
func expand(_ settings: ResizeSettings, sourceSize: CGSize?) -> [ResizeSettings]
```

| Mode | Rung `400` yields | Notes |
|---|---|---|
| Fit | `width = 400`, height `nil` | Proportional |
| Fill | `400 × 225` when the UI ratio is 1600×900 | Uniform crop across the ladder |
| Long Edge | `longEdge = 400` | Direct |
| Percentage | — | Mutually exclusive; ladder disabled |

**Consequences of doing it this way — all of them good:**

- `ResizeMath`, `render`, `renderableFrame`, the JPEG bisection, and the WebP subprocess
  path are **entirely untouched**.
- `expand` is pure math over `Models.swift` types, so it drops straight into
  `Checks/main.swift` — the unit-check compile unit already includes `Models.swift` and
  `JobPlanner.swift`.
- Progress accounting keeps working; the total is just larger.

**Two details this surfaces:**

- **`skipUpscales` needs the source pixel size at plan time.**
  `JobPlanner.isReadableImage` already opens a `CGImageSource` and discards it. It would
  read dimensions from `CGImageSourceCopyPropertiesAtIndex` instead — cheap, no decode.
- **`skipUpscales` must *drop* rungs, not clamp them.** The existing
  `preventEnlargement` flag clamps scale to ≤ 1, so a 500px-wide source against a
  400/800/1200 ladder would silently produce 400/500/500 — two identical files with
  different names. Rungs wider than the source have to be removed from the plan.

---

## 4. Cross-cutting: resolve filenames at plan time

Right now final filenames are decided **during encoding**: `ResizeEngine` calls
`availableURL(for:)`, which probes the filesystem with `FileManager.fileExists` and
appends `-2`, `-3`… That logic is duplicated in `WebPCodec`.

That has to move. **Slugification makes collisions common rather than rare** — `IMG_1234.jpg`,
`img 1234.png`, and `IMG-1234.jpeg` all slug to `img-1234` — and feature 6 needs every
final filename *before* any file is written, because the manifest and the `<picture>`
snippet describe the whole output set.

**Recommendation:** a single name-resolution pass in `JobPlanner`, holding a
batch-scoped `Set<String>` of reserved names, replacing both copies of `availableURL`.
Names become deterministic and known up front.

Note that a collision is a collision **only within the same format**: `chair-400.avif`
and `chair-400.jpg` coexist happily; two different sources both slugging to `chair-400`
in the same format do not.

This is the one change that several later features depend on, which is why feature 1
goes first.

---

## 5. Where each feature attaches

### 1. Filename slugification → `Models.swift`

Replaces `ResizeJob.requestedOutputURL(extension:filenameSuffix:)`, whose sanitiser
currently only maps control characters, `/`, and `:` to `-`.

Template tokens: `{slug}`, `{original}`, `{width}`, `{height}`, `{format}`, `{index}`.
The existing `filenameSuffix` setting is subsumed — a non-web-export run is the template
`"{original}{suffix}"`, preserving today's behaviour exactly.

Stays in `Models.swift`, so it stays pure string math inside the unit-check compile unit.
Best-covered feature of the seven, and the natural first PR.

### 2. Responsive ladder → `JobPlanner.swift` (+ `Models.swift`)

`expand(_:sourceSize:)` as described above, called from `JobPlanner.plan`. Pure; fully
unit-checkable.

### 3. AVIF → `Models.swift` + `ResizeEngine.swift`

Verified: `public.avif` **is** in `CGImageDestinationCopyTypeIdentifiers()` on macOS 26.5,
so no vendored encoder is needed — unlike WebP, which ImageIO cannot write and which is
why `WebPCodec` shells out.

- `OutputFormat` gains `.avif` → `typeIdentifier` `"public.avif"`,
  `preferredExtension` `"avif"`.
- `ResizeEngine.extensionFor(type:fallback:)` gains a case.
- The existing guard `writableTypes.contains(requestedType)` already throws a clean
  `unsupportedOutput` on systems that can't write it, so older macOS degrades to a
  readable error rather than crashing.

**Open:** `supportsTargetFileSize` — AVIF is lossy, so target-file-size *should* apply,
but the bisection branch is hardcoded to `requestedType == jpeg`. Either generalise it
to any lossy ImageIO type or leave AVIF out of target-sizing in the first pass.

**Unverified:** which macOS version first added AVIF **write**. Needs pinning down before
we promise AVIF on the macOS 14 floor.

### 4. Force-sRGB → `ResizeEngine.swift` + `WebPCodec.swift`

Mostly **subtractive**. `render` already builds its context in `CGColorSpace.sRGB`, so
pixels are already converted. The bug is that `preserveMetadata` copies the source's
profile properties back over the output, mislabelling wide-gamut sources.

- `ResizeEngine`: strip profile keys from copied container and frame properties;
  optionally embed a compact sRGB ICC profile.
- `WebPCodec`: `copyWebPMetadata` currently copies the source `icc` chunk
  unconditionally — this is the same bug on the WebP path and this feature fixes it.

Smallest of the seven.

### 5. IPTC/XMP write-back → `ResizeEngine.swift` + `WebPCodec.swift`

The first feature that **authors** metadata rather than copying it.

- IPTC (Creator, Copyright, Credit, Title, Description) maps onto
  `kCGImagePropertyIPTCDictionary` and merges into `outputProperties`.
- **XMP does not.** `xmpRights:WebStatement` and `plus:Licensor` have no ImageIO
  property key. They need `CGImageMetadata` built explicitly and written via
  `CGImageDestinationAddImageAndMetadata` — **a different call from the
  `CGImageDestinationAddImage` used today**, inside the multi-frame loop. This is the
  riskiest of the seven and deserves its own PR with no other changes in it.
- WebP: XMP goes through `webpmux -set xmp` with a **generated** packet, rather than a
  chunk copied from the source.
- Interaction to preserve: `removeLocation` must keep stripping GPS *after* this merge.

Title/Description arrive per-image per the policy in `RightsMetadata`; the preset never
carries their text.

### 6. Sidecars → new file, e.g. `SidecarWriter.swift`

Runs **after** the batch, and needs the complete plan — every rung, every format, every
final filename — which is exactly what §4 provides.

Requires `BatchResult` to carry per-source output records rather than just
`outputDirectories: [URL]`:

```json
{
  "generator": "Image Resizer",
  "images": [{
    "source": "IMG_4821.CR3",
    "slug": "red-chair",
    "alt": "A red chair against a white wall.",
    "lqip": "data:image/jpeg;base64,…",
    "renditions": [
      { "path": "/images/red-chair-400.avif", "width": 400, "height": 225,
        "format": "avif", "bytes": 8134 }
    ]
  }]
}
```

The `<picture>` snippet is generated from the same records; `pathPrefix` and
`sizesAttribute` are pure string composition. LQIP reuses the existing render path at
~20px and base64-encodes the result — no new dependency.

Keep this file UI-free and add it to both `swiftc` lists in `check.sh`; snippet and
manifest generation is string math and should be checked.

### 7. Alt text → new file, e.g. `AltTextProvider.swift`

```swift
protocol AltTextProvider {
    func altText(for image: CGImage) async -> String?
}

struct VisionAltTextProvider: AltTextProvider { … }              // macOS 14+

@available(macOS 26, *)
struct FoundationModelsAltTextProvider: AltTextProvider { … }
```

Feeds two consumers: `RightsMetadata.descriptionPolicy == .fromAltText`, and the `alt`
attribute in the `<picture>` snippet.

Both run entirely on-device. Vision returns **labels** (`"chair, furniture, indoor"`);
Foundation Models returns a **sentence** (`"A wooden chair against a white wall."`).
Deployment target stays at macOS 14 and the better engine is gated behind `#available`.

**Blocker, and the reason this goes last.** `Scripts/check.sh` pins
`MacOSX15.4.sdk` when present, and CI runs on `macos-15`:

```
MacOSX15.4.sdk  → FoundationModels: absent    Vision: present
MacOSX26.5.sdk  → FoundationModels: present   Vision: present
```

`#available` is a **runtime** mechanism — it does not help if the SDK lacks the
framework at build time. Shipping the Foundation Models path requires bumping both the
`check.sh` SDK and the workflow runner to macOS 26. Vision has no such problem.

---

## 6. Suggested delivery order

Each row is one PR off `main`. The order is a dependency order, not a preference.

| # | PR | Depends on | Notes |
|---|---|---|---|
| 0 | Widen `ResizePreset`, add `WebExport` shell, preset apply/persist | — | No behaviour change; pure groundwork |
| 1 | Slugification + plan-time name resolution | 0 | Also de-duplicates `availableURL` |
| 2 | Responsive ladder | 0, 1 | Pure `expand`; needs source size at plan time |
| 3 | AVIF output | 0 | Independent of 1 and 2 |
| 4 | Force-sRGB | — | Smallest; independent; could go anytime |
| 5 | IPTC/XMP write-back | 0 | Riskiest; changes the destination write call |
| 6 | Sidecars | 1, 2, 3 | Needs the full resolved plan |
| 7 | Alt text | 5, 6 | Needs SDK 26 in CI for the Foundation Models path |

PR 0 is worth doing on its own precisely because it changes no behaviour — it lands the
type and the persistence, and every later PR is then additive.

---

## 7. Open questions

1. **AVIF target-file-size** — generalise the quality bisection to any lossy ImageIO
   type, or exclude AVIF from target-sizing initially?
2. **AVIF write floor** — which macOS version first supports writing `public.avif`?
   Determines whether it can be offered on the macOS 14 deployment target.
3. **Output volume** — 20 images × 4 rungs × 3 formats is 240 files through a **serial**
   batch loop, with every WebP file a separate `img2webp` subprocess. Parallelising the
   loop is out of scope here, but the UI should show the multiplication
   ("20 images → 240 files") before the user commits.
4. **Per-image Title/Description UI** — this design defines the slot and defers the
   editor. Worth deciding whether it's an inspector in the sidebar or a post-batch
   review step before feature 5 ships.
5. **Ladder in Fill mode** — the aspect ratio is inferred from the width/height fields.
   Should the preset store an explicit ratio instead, so a preset isn't silently
   dependent on two unrelated text fields?
