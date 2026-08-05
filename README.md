# Image Resizer

A native Apple Silicon macOS app for resizing large batches of images while preserving their folder structure.

![Image Resizer app icon](Resources/AppIcon/ImageResizer-Icon.png)

## Features

- Drop individual images, folders, or multiple folders.
- Resize by fitting inside a box, filling and center-cropping, setting the long edge, or scaling by percentage.
- Avoid enlarging smaller images by default, with an option to allow upscaling.
- Preserve the source format or convert to JPEG, PNG, HEIC, TIFF, GIF, WebP, or AVIF when macOS supports writing it.
- Crop around the subject rather than the middle, recognised on this Mac, so a fill crop keeps what the picture is of.
- Preserve multi-frame animation and per-frame timing for writable animated formats.
- Preserve metadata while removing GPS location data by default.
- Recreate source subfolders inside a sibling `Folder - Resized` output folder.
- Add a remembered, editable filename suffix (`-resized` by default), or leave it blank to retain original filenames.
- Export JPEG, HEIC, AVIF, and WebP images under an optional KB or MB file-size limit at the highest quality that fits.
- Pause, resume, cancel, saved presets, remembered settings, and collision-safe filenames.
- Clear completed sources automatically while keeping the batch summary and output location available.
- Automatic update checks plus a manual **Check for Updates…** command.
- RAW sources fall back to JPEG when “Keep Original” is selected.
- Camera RAW files, including Canon CR3, use their embedded color-rendered preview for reliable resizing.

## Web Export

An optional mode that makes a batch ready to publish. Everything runs on this Mac — nothing is uploaded, and URLs you enter are written as text, never fetched.

- Rename files to web-safe slugs, transliterating other scripts and dropping camera prefixes like `IMG_`, with `{token}` templates for the rest.
- Generate a responsive ladder of widths, skipping sizes larger than a given original.
- Write each image in more than one format — AVIF and WebP alongside a fallback every browser reads.
- Convert to sRGB, with the profile embedded or left off.
- Write creator, copyright, credit, and licensing metadata into IPTC and XMP.
- Suggest alt text on device: Vision recognises the image and, on macOS 26, the on-device language model phrases it. Images it is unsure about are left undescribed.
- Crop a link preview and write the `og:image` tags that go with it.
- Write `manifest.json` describing every file, and a ready-to-paste snippet as HTML or JSX.

The snippet is markup you can use as it stands: a `<picture>` offering each format, a `srcset` of every width, a `sizes` attribute generated from how wide the image sits on your page, intrinsic dimensions so the page does not shift, `schema.org` structured data carrying the licensing fields, and priority hints that load the first image eagerly and defer the rest.

Animated WebP writing uses the bundled Google libwebp 1.6.0 command-line codec under its BSD-style license. With location removal enabled, WebP EXIF/XMP metadata is omitted to ensure embedded location fields are not retained; ICC color profiles are preserved.

Updates use Sparkle 2 under its permissive open-source license. Release archives are cryptographically signed, and the public feed contains no application source.

## Develop

```sh
./Scripts/check.sh
swift build --disable-sandbox
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
