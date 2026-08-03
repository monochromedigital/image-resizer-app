# Image Resizer

A native Apple Silicon macOS app for resizing large batches of images while preserving their folder structure.

![Image Resizer app icon](Resources/AppIcon/ImageResizer-Icon.png)

## Features

- Drop individual images, folders, or multiple folders.
- Fit proportionally inside a width/height bounding box; either dimension may be omitted.
- Avoid enlarging smaller images by default, with an option to allow upscaling.
- Preserve the source format or convert to JPEG, PNG, HEIC, TIFF, GIF, or WebP when macOS supports writing it.
- Preserve multi-frame animation and per-frame timing for writable animated formats.
- Preserve metadata while removing GPS location data by default.
- Recreate source subfolders inside a sibling `Folder - Resized` output folder.
- Pause, resume, cancel, saved presets, remembered settings, and collision-safe filenames.
- Clear completed sources automatically while keeping the batch summary and output location available.
- Automatic update checks plus a manual **Check for Updates…** command.
- RAW sources fall back to JPEG when “Keep Original” is selected.
- Camera RAW files, including Canon CR3, use their embedded color-rendered preview for reliable resizing.

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

Versioned DMGs, SHA-256 checksums, and the Sparkle appcast are published through the public [Image Resizer Releases](https://github.com/monochromedigital/image-resizer-releases) repository.

Every push to `main` runs the repository's GitHub Actions release workflow. After checks pass, it assigns the next patch version, publishes the signed update, and refreshes the Sparkle feed. For example, if the latest public release is `0.1.1`, the next push publishes `0.1.2`.

The local script remains available as a manual fallback:

```sh
./Scripts/release.sh 0.1.1
```

See [RELEASING.md](RELEASING.md) for validation, versioning, installation, and recovery details.
