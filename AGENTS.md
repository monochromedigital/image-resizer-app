# Agent context — Image Resizer

A native Apple Silicon macOS app for batch image resizing. SwiftPM package, no Xcode
project. Ships to real users as a signed Sparkle update.

Live site: resizer.monochrome.digital

## Hard constraints

Read these first. Both are non-negotiable.

### 1. The app is offline-only

No network calls, no accounts, no telemetry, ever. This is the product's entire
positioning, not a preference. Any feature that requires a network request is out of
scope — propose an on-device alternative or say it can't be done.

This includes indirect network access: no analytics SDKs, no crash reporters, no font
or asset CDNs, no "check if this URL resolves" validation. URLs the user types (for
example licensing URLs written into image metadata) are stored and written as **plain
strings** and are never fetched or resolved.

The one existing network consumer is Sparkle, which checks the public appcast for
updates. That is deliberate, pre-existing, and user-triggerable via
**Image Resizer → Check for Updates…**.

### 2. Never push to `main`

Every push to `main` triggers `.github/workflows/release-on-push.yml`, which assigns
the next patch version and publishes a **signed Sparkle update to real users**. There
is no staging step and no manual gate. A documentation-only push still ships a release.

All work happens on a feature branch and merges via PR:

```sh
git checkout -b agent/short-description
# ... work, commit ...
git push -u origin agent/short-description
gh pr create
```

Do not push to `main`, do not merge your own PR without being asked, and do not run
`Scripts/release.sh` (the manual publishing fallback).

See [RELEASING.md](RELEASING.md) for the full release mechanics.

## Layout

```
Package.swift            swift-tools 5.10, macOS 14+, one executable target
sources/ImageResizer/    all app code, 15 flat files, no subdirectories
Checks/                  the real test suite (see Testing below)
Tests/ImageResizerTests/ NOT built — see Testing below
Scripts/                 check.sh, package.sh, release.sh, ci-release.sh, make-icns.js
Vendor/WebPTools/        bundled libwebp 1.6.0 CLI binaries (cwebp, img2webp, webpmux)
Resources/               Info.plist, AppIcon
```

**Directory case gotcha:** git tracks the source directory as lowercase `sources/`, but
`Package.swift` (via SwiftPM's implicit path) and `Scripts/check.sh` (explicitly) both
refer to `Sources/`. This only works because macOS's default filesystem is
case-insensitive. Don't "fix" one side in isolation, and be aware that a case-sensitive
volume will break the build.

## Architecture

Layered, one-way, no protocols or dependency injection. Everything below the view model
is free functions over value types.

```
ImageResizerApp          @main, WindowGroup + Settings scene, Sparkle updater
  └── ResizeViewModel    @MainActor, owns sources + batch lifecycle, holds SettingsStore
        └── SettingsStore    @MainActor, UserDefaults-backed, vends ResizeSettings
              └── JobPlanner     walks sources → [ResizeJob]
                    └── ResizeEngine   one ResizeJob → one output file
                          └── WebPCodec    WebP only, shells out to img2webp
```

### The files

| File | Holds |
|---|---|
| `Models.swift` | Every value type. `ResizeSettings` (the settings bundle), `ResizePreset`, `ResizeJob`, `BatchProgress`/`BatchResult`, the format/mode enums, `OutputType` (container-type resolution), and `ResizeMath` (pure layout math). No file I/O. |
| `WebExport.swift` | The web-export config tree: `WebExport` plus its per-feature sub-structs (`Naming`, `Ladder`, `AspectRatio`). All `Codable`, all leniently decoded. |
| `OutputNaming.swift` | Filename construction — slugging, transliteration, `{token}` templates — plus `NameReservations`, which hands out collision-free output URLs. |
| `SizeLadder.swift` | `expand(_:sourceSize:)`: one `ResizeSettings` in, one per ladder rung out. Pure. |
| `FormatMatrix.swift` | `expand(_:writable:)`: the same trick for formats, fallback last. Filters out what ImageIO cannot write and what would duplicate the fallback. Pure. |
| `RightsWriter.swift` | The only place metadata is *authored*. Builds the IPTC dictionary and the `CGImageMetadata` for XMP-only fields. |
| `SidecarWriter.swift` | `manifest.json`, `snippet.html`, and inline placeholders, assembled from the renditions a batch recorded. |
| `AltTextGenerator.swift` | On-device alt text: Vision classifies, the on-device language model phrases. Both stages local. |
| `SaliencyFinder.swift` | Where the subject is, via Vision's attention saliency, so a crop can be anchored on it. Returns a normalised point or nothing. |
| `JobPlanner.swift` | Enumerates sources into `[ResizeJob]`, **resolves every output filename**, decides output directory names, skips unreadable files. Touches FileManager and ImageIO. |
| `ResizeEngine.swift` | The pipeline. `resize(job:)` is the core: open source → pick output type → render frames → write via `CGImageDestination`. Also the serial batch loop, the quality bisection, and `ProcessingControl` (lock-based pause/cancel). |
| `WebPCodec.swift` | WebP output. ImageIO cannot *write* WebP, so this renders frames to intermediate `.pam` files in a temp dir and shells out to the bundled `img2webp`; `webpmux` copies ICC/EXIF/XMP chunks. |
| `SettingsStore.swift` | ~21 `@Published` properties, each `didSet { save() }`, persisted as discrete `UserDefaults` keys. Computed `var settings: ResizeSettings` adapts them for the layers below. |
| `ResizeViewModel.swift` | `@MainActor`. Source list, batch start/pause/cancel, progress, `NSOpenPanel` presentation, Finder reveal. |
| `ContentView.swift` | The whole UI in one struct plus `SettingsView`. `NavigationSplitView`: sidebar of sources, detail of `GroupBox` sections, fixed action bar. |
| `ImageResizerApp.swift` | Scenes, Sparkle wiring, menu commands. |
| `CheckForUpdatesView.swift` | Sparkle's menu item. |

### Things worth knowing before you change the pipeline

- **One job → one output file.** `ResizeEngine.resize` returns a single `URL`, and
  `progress.completed += 1` counts jobs. Anything that fans one source out to several
  outputs fans out in `JobPlanner`, producing more `ResizeJob`s — that is how the size
  ladder, the format matrix and the share image all work, and it is why the engine needed
  no changes for any of them. They compose: formats outermost, rungs within, then one
  share image per source, so a source's files stay contiguous and in the order the markup
  offers them.
- **Two settings are filled in after planning, not by the planner.** Alt text and the
  crop focus both need pixels the planner deliberately never decodes, so `ResizeViewModel`
  runs a pre-pass per *source* — not per job, or a ladder would ask the same question four
  times — and calls `ResizeJob.adding(altText:focus:)`. Neither affects the output size or
  the resolved filename, which is why a job can take them on after the fact. Rebuild jobs
  through that method rather than by hand; constructing a `ResizeJob` inline is how a
  field like `role` gets silently dropped.
- **A `Rendition` carries a `RenditionRole`.** `.social` marks the link-preview crop,
  which is a *different picture* rather than a smaller one — it must never reach a
  `srcset`, and `SidecarWriter` splits it out before grouping by format. Anything that
  adds a rendition that is not one size of the same image needs a role, not a filter on
  its name.
- **Filenames are resolved at plan time, not during encoding.** `JobPlanner` fills in
  `ResizeJob.output` completely: extension, naming template, and collision suffix.
  `NameReservations` checks both the batch's own reservations and the disk, so two
  sources that slug to the same stem cannot collide. Don't reintroduce naming in the
  engine.
- **A `ResizeJob` carries its own `ResizeSettings`** and is only valid for them — its
  resolved filename was derived from them. Don't resize a job under different settings.
- **The batch loop is serial.** `ResizeEngine.process` is a plain `for` over jobs on one
  detached task. Fine today; it becomes noticeable if output volume multiplies.
- **Two encoding paths.** ImageIO `CGImageDestination` for JPEG/PNG/HEIC/TIFF/GIF/AVIF;
  a subprocess for WebP. Any change to output — naming, metadata, colour — usually has
  to be made **twice**, once in `ResizeEngine` and once in `WebPCodec`.
- **`render` always targets an sRGB context**, so output pixels are always sRGB
  regardless of the source. There is no way to preserve a wide-gamut pipeline, which
  means a source's colour profile is never valid for the output.
  ImageIO handles the tagging correctly on its own: `CGImageDestination` embeds the
  colour space of the `CGImage` it is handed, which overrides any profile properties
  copied by `preserveMetadata`. Verified — a Display P3 source comes out of the JPEG and
  PNG paths tagged `sRGB IEC61966-2.1`.
  **WebP is the exception**, because the encoder only sees raw PAM pixels and cannot know
  the colour space. See `embedSRGBProfile`.
- **`OutputType.isLossy` gates two separate things** — whether the quality key is set,
  and whether target-file-size bisection applies. A lossy format missing from it silently
  ignores the quality slider. Add new formats there, not to an inline comparison.
- **Metadata is copy-through only.** `preserveMetadata` copies container and per-frame
  properties; `removeLocation` deletes exactly one key
  (`kCGImagePropertyGPSDictionary`). There is no metadata *authoring* path. For WebP,
  `removeLocation` instead drops EXIF and XMP wholesale and keeps only ICC.
- **`ResizeSettings` is `Equatable` but not `Codable`**; `ResizePreset` is `Codable`.
- **`FoundationModels` is weak-linked.** It does not exist before macOS 26 and the
  deployment target is 14, so a strong link would stop the app launching on every older
  system. The toolchain weak-links it automatically given the `@available` annotations;
  `Package.swift` also says so explicitly. If you touch either, check with
  `otool -L` that the entry still says `(weak)`.
- **The on-device language model cannot see images.** Its `Prompt` takes strings only, so
  alt text is Vision-then-phrase, never one model. Anything that asks it to describe a
  picture directly is asking for invention.
- **`ResizeEngine.process` records a `Rendition` per written file**, read back from the
  output's header rather than from what was requested. The sidecars describe files a
  browser will fetch, so they have to match what is on disk. Anything that adds an output
  path must record it too, or it will be missing from the manifest.

## Build, run, test

```sh
./Scripts/check.sh
```

```sh
swift build --disable-sandbox
```

```sh
swift run ImageResizer
```

```sh
./Scripts/package.sh
```

`package.sh` produces `dist/Image Resizer.app` and an unsigned Apple Silicon
`dist/Image Resizer.dmg`.

### Testing

**`Tests/ImageResizerTests/` is not built and never runs.** `Package.swift` declares
exactly one target (the executable), so SwiftPM never compiles it and `swift test` does
nothing with it. Its contents duplicate `Checks/main.swift` and have already drifted out
of sync. Don't add coverage there expecting it to run.

**`Checks/` is the real suite**, and `Scripts/check.sh` is the entire CI gate
(`ci-release.sh` runs `check.sh` then `package.sh`). `check.sh` does not use SwiftPM. It
invokes `swiftc` directly, twice, over a **hand-listed set of files**:

1. **Unit checks** — compiles `Models.swift`, `WebExport.swift`, `OutputNaming.swift`,
   `SizeLadder.swift`, `JobPlanner.swift` + `Checks/main.swift`. Pure math, string, and
   `Codable` assertions; `check(_:_:)` exits non-zero on failure.
2. **Integration checks** — adds `ResizeEngine.swift` + `WebPCodec.swift` +
   `Checks/Integration.swift`. Generates PNG fixtures and round-trips them through the
   real engine, asserting on dimensions, filename suffixes and collision naming, all
   four resize modes, target-file-size bisection for JPEG and WebP, animated GIF/WebP
   frame counts, and an optional camera-RAW path gated on `$IMAGE_RESIZER_RAW_FIXTURE`.

Two consequences for new code:

- **If you add a source file that checks need, add it to the `swiftc` file lists in
  `check.sh`.** Nothing is discovered automatically.
- **Both compile units are UI-free.** `Models`, `JobPlanner`, `ResizeEngine`, and
  `WebPCodec` import no SwiftUI, and that is what makes them compilable in isolation.
  Putting testable logic in a file that imports SwiftUI makes it untestable under this
  harness. Prefer to put pure logic in `Models.swift` (or a new UI-free file added to
  both lists).

SDK resolution in `check.sh` and `package.sh` is `$IMAGE_RESIZER_SDK` → whatever
`xcrun` considers current. The CI runner is `macos-26`. Both were previously pinned to
`MacOSX15.4.sdk`, which made local runs disagree with CI and withheld frameworks added
since — availability gating is a runtime mechanism, so an `#available` check does not
help if the SDK lacks the framework at build time.

**The deployment target is set by `Package.swift` (`.macOS(.v14)`), not by the SDK.**
Building against a newer SDK does not raise it; the shipped binary reports `minos 14.0`.
Verify with `vtool -show-build "dist/Image Resizer.app/Contents/MacOS/ImageResizer"` if
you touch any of this.

Note that some capabilities are gated by the *running* OS rather than the SDK. AVIF is
writable on macOS 26 and not on macOS 15, which is why `OutputFormat.writable` probes
ImageIO at launch instead of testing a version. Checks that depend on such a capability
should be guarded on the same probe and should print which branch they took, so a skip
is visible in the log rather than looking like a pass.

## Conventions

Observed in the existing code — match them.

- **Value types by default.** `struct`/`enum` for models. Classes only where identity is
  required: `ObservableObject` view model and store, plus `ProcessingControl`.
- **`enum` as a namespace** for stateless helpers with only static members
  (`ResizeMath`, `JobPlanner`, `WebPCodec`). Never instantiated. `ResizeEngine` is a
  `struct` used the same way.
- **Modern Swift expression syntax.** `if`/`switch` used as expressions for returns and
  assignments, e.g. `case .original: nil` inside a computed property. No `return`
  keyword where the expression form works.
- **Errors are per-subsystem `enum`s conforming to `LocalizedError`** with a
  `switch`-expression `errorDescription`. User-facing sentences, ending in a period,
  naming the file where useful (`"Could not read \(url.lastPathComponent)."`).
- **Force-unwrap only known-good constants** — `CGColorSpace(name: .sRGB)!`,
  `OutputFormat.jpeg.typeIdentifier!`. Never force-unwrap anything derived from user
  input or file contents.
- **Full words, no abbreviations.** `preventEnlargement`, `targetFileSizeBytes`,
  `requestedOutputURL`. Booleans read as assertions.
- **ImageIO property dictionaries are `[CFString: Any]`**, keys are the `kCGImageProperty*`
  constants.
- **Comments are rare and explain *why*, not *what*.** The RAW-preview comment in
  `ResizeEngine.renderableFrame` is the model: it exists because the reason isn't
  recoverable from the code. Don't narrate.
- **UI strings live inline in the view.** Sentence case, typographic quotes (`“ ”`) and
  ellipses (`…`). Buttons that open something end in `…`.
- **SwiftUI state is `ObservableObject` + `@EnvironmentObject`**, not `@Observable`.
  Store bindings go through the single generic `binding(_:)` keypath helper in
  `ContentView`, not ad-hoc `Binding(get:set:)`.
- **No new third-party dependencies.** Sparkle is the only one, and vendored binaries
  (libwebp) ship under `Vendor/` with their licences.

## Web Export

All seven features that make output web- and SEO-ready have shipped: slugged filenames,
the size ladder, AVIF, forced sRGB, IPTC/XMP rights write-back, sidecars, and on-device
alt text. [docs/web-export-preset.md](docs/web-export-preset.md) is the reference for how
they are shaped and why — read it before touching preset modelling, filename generation,
or metadata.

Read its §10 first. That section records where implementation disproved the design, and
those are the claims most likely to mislead: force-sRGB turned out to be a no-op on the
ImageIO path and a real bug only on the WebP one, and the alt-text feature was designed
on a false premise about what the on-device language model can see.

`FormatPlan` shipped last and shipped smaller than designed: it carries a list of
**alternative** formats, and the run's own format stays the fallback rather than being a
plan entry of its own. Per-entry target file sizes were not built — an alternative
inherits the run's quality and size limit, minus the limit if the format is lossless.
