# Image Resizer

A native Apple Silicon macOS app for resizing large batches of images while preserving their folder structure.

![Image Resizer app icon](Resources/AppIcon/ImageResizer-Icon.png)

## Features

- Drop individual images, folders, or multiple folders.
- Fit proportionally inside a width/height bounding box; either dimension may be omitted.
- Preserve the source format or convert to JPEG, PNG, HEIC, TIFF, GIF, or WebP when macOS supports writing it.
- Preserve multi-frame animation and per-frame timing for writable animated formats.
- Preserve metadata while removing GPS location data by default.
- Recreate source subfolders inside a sibling `Folder - Resized` output folder.
- Pause, resume, cancel, saved presets, remembered settings, and collision-safe filenames.
- Automatic update checks plus a manual **Check for Updates…** command.
- RAW sources fall back to JPEG when “Keep Original” is selected.

Animated WebP writing uses the bundled Google libwebp 1.6.0 command-line codec under its BSD-style license. With location removal enabled, WebP EXIF/XMP metadata is omitted to ensure embedded location fields are not retained; ICC color profiles are preserved.

Updates use Sparkle 2 under its permissive open-source license. Release archives are cryptographically signed, and the public feed contains no application source.

## Develop

```sh
./Scripts/check.sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk swift build --disable-sandbox
swift run ImageResizer
```

## Package

```sh
./Scripts/package.sh
```

The packaging script creates `dist/Image Resizer.app` and an unsigned Apple Silicon `dist/Image Resizer.dmg`.

## Release

Source remains private. Versioned DMGs, SHA-256 checksums, and the Sparkle appcast are published through the public [Image Resizer Releases](https://github.com/johnny-bm/image-resizer-releases) repository.

```sh
./Scripts/release.sh 0.1.1
```

See [RELEASING.md](RELEASING.md) for validation, versioning, installation, and recovery details.
