# Releasing Image Resizer

The Swift source stays in the private `johnny-bm/image-resizer` repository. Public binaries and checksums are published to [`johnny-bm/image-resizer-releases`](https://github.com/johnny-bm/image-resizer-releases).

## Prerequisites

- Work on the `main` branch with all tracked changes committed and pushed.
- Authenticate GitHub CLI as `johnny-bm` with `gh auth login -h github.com`.
- Keep the source repository private and the releases repository public.
- Choose a version newer than the value in `Resources/Info.plist`.
- Keep the Sparkle private key in the login Keychain under the `image-resizer` account.

Untracked working files do not block a release and are never uploaded.

## Publish

```sh
./Scripts/release.sh 0.1.1
```

To provide custom release notes:

```sh
./Scripts/release.sh 0.2.0 --notes-file release-notes.md
```

To publish without replacing the local app:

```sh
./Scripts/release.sh 0.2.0 --no-install
```

The script pauses for confirmation before changing versions or publishing. It then:

1. Verifies repository visibility and synchronized branches.
2. Increments `CFBundleVersion` and sets `CFBundleShortVersionString`.
3. Runs sizing, folder, format, animated GIF, and animated WebP checks.
4. Builds and verifies the app and DMG.
5. Signs the DMG with the private Sparkle key and generates `appcast.xml`.
6. Commits and tags the private source repository.
7. Publishes `ImageResizer.dmg`, its checksum, and the appcast publicly.
8. Atomically replaces and relaunches the local app.

If publishing succeeds but local installation fails, the GitHub release remains valid. Download it from the public releases repository and install it manually.

## Version rules

- Patch release: `0.1.0` → `0.1.1` for bug fixes.
- Minor release: `0.1.0` → `0.2.0` for new features.
- Major release: `0.x.y` → `1.0.0` for a stable public milestone or breaking changes.

Every release increments the internal build number automatically.

## Automatic updates

Sparkle checks the public appcast while all Swift source remains private. Users can also choose **Image Resizer → Check for Updates…**. A release is not offered until its signed DMG exists in the public GitHub release and the matching appcast has been pushed.

The signing key is the identity of every future update. Losing it prevents existing installations from accepting new releases. Back it up once to secure offline storage (never inside either repository):

```sh
.build-release/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account image-resizer \
  -x /path/to/secure/offline/ImageResizer-Sparkle-private-key
```

On a replacement Mac, import that backup with the same tool and `-f` instead of `-x`.
