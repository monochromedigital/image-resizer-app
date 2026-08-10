#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PLIST="$ROOT/Resources/Info.plist"
APP="$ROOT/dist/Image Resizer.app"
DMG="$ROOT/dist/Image Resizer.dmg"
SOURCE_REPO="monochromedigital/image-resizer-app"
RELEASE_REPO="monochromedigital/image-resizer-releases"
INSTALL_DIR="${IMAGE_RESIZER_INSTALL_DIR:-/Applications}"
SPARKLE_ACCOUNT="image-resizer"

VERSION=""
NOTES_FILE=""
INSTALL_APP=true
ASSUME_YES=false

usage() {
  cat <<'USAGE'
Usage: ./Scripts/release.sh VERSION [options]

Create and publish a versioned Image Resizer release.

Arguments:
  VERSION                 Semantic version in X.Y.Z form, for example 0.2.0

Options:
  --notes-file PATH       Markdown release notes to publish
  --no-install            Do not update the local app after publishing
  --yes                   Skip the final confirmation prompt
  -h, --help              Show this help

The script:
  1. Validates the repository, version, GitHub access, and clean tracked files.
  2. Increments the build number and runs checks.
  3. Builds and verifies the Apple Silicon app and DMG.
  4. Signs the update and generates the public Sparkle appcast.
  5. Commits and tags the source repository.
  6. Publishes the DMG, checksum, and appcast publicly.
  7. Replaces the local app in /Applications unless --no-install is used.
USAGE
}

fail() {
  print -u2 -- "Release stopped: $*"
  exit 1
}

while (( $# > 0 )); do
  case "$1" in
    --notes-file)
      (( $# >= 2 )) || fail "--notes-file requires a path."
      NOTES_FILE="$2"
      shift 2
      ;;
    --no-install)
      INSTALL_APP=false
      shift
      ;;
    --yes)
      ASSUME_YES=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      fail "Unknown option: $1"
      ;;
    *)
      [[ -z "$VERSION" ]] || fail "Only one version may be supplied."
      VERSION="$1"
      shift
      ;;
  esac
done

[[ -n "$VERSION" ]] || { usage; exit 2; }
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "Version must use X.Y.Z, for example 0.2.0."
[[ -z "$NOTES_FILE" || -r "$NOTES_FILE" ]] || fail "Release notes file is not readable: $NOTES_FILE"

for command in git gh plutil shasum hdiutil codesign ditto xmllint; do
  command -v "$command" >/dev/null || fail "Required command is missing: $command"
done

cd "$ROOT"
[[ "$(git rev-parse --show-toplevel)" == "$ROOT" ]] || fail "Run this from the Image Resizer repository."
[[ "$(git branch --show-current)" == "main" ]] || fail "Releases must be created from main."
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || fail "Commit or discard tracked changes before releasing."
[[ "$(git remote get-url origin)" == *"$SOURCE_REPO"* ]] || fail "origin is not $SOURCE_REPO."

gh auth status -h github.com >/dev/null || fail "GitHub CLI authentication is required. Run: gh auth login -h github.com"
SOURCE_VISIBILITY="$(gh repo view "$SOURCE_REPO" --json visibility --jq .visibility)"
RELEASE_VISIBILITY="$(gh repo view "$RELEASE_REPO" --json visibility --jq .visibility)"
[[ "$SOURCE_VISIBILITY" == "PUBLIC" ]] || fail "$SOURCE_REPO must remain public."
[[ "$RELEASE_VISIBILITY" == "PUBLIC" ]] || fail "$RELEASE_REPO must be public."

git fetch --quiet origin main --tags
[[ -z "$(git rev-list --left-right --count main...origin/main | tr -d '0\t ')" ]] || fail "Local main and origin/main are not synchronized."

CURRENT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
TAG="v$VERSION"
git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null && fail "Tag $TAG already exists."
gh release view "$TAG" --repo "$RELEASE_REPO" >/dev/null 2>&1 && fail "Public release $TAG already exists."

typeset -a current_parts target_parts
current_parts=( ${(s:.:)CURRENT_VERSION} )
target_parts=( ${(s:.:)VERSION} )
IS_NEWER=false
for index in 1 2 3; do
  if (( target_parts[index] > current_parts[index] )); then
    IS_NEWER=true
    break
  elif (( target_parts[index] < current_parts[index] )); then
    break
  fi
done
[[ "$IS_NEWER" == true ]] || fail "$VERSION must be newer than $CURRENT_VERSION."

NEXT_BUILD=$(( target_parts[1] * 1000000 + target_parts[2] * 1000 + target_parts[3] ))
(( NEXT_BUILD > CURRENT_BUILD )) || fail "Calculated build $NEXT_BUILD must be newer than $CURRENT_BUILD."
print -- "Image Resizer release plan"
print -- "  Version:       $CURRENT_VERSION ($CURRENT_BUILD) -> $VERSION ($NEXT_BUILD)"
print -- "  Source:         https://github.com/$SOURCE_REPO"
print -- "  Public release: https://github.com/$RELEASE_REPO/releases/tag/$TAG"
print -- "  Local install:  $INSTALL_APP ($INSTALL_DIR/Image Resizer.app)"

if [[ "$ASSUME_YES" != true ]]; then
  read "reply?Proceed with build, push, and public release? [y/N] "
  [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]] || fail "Cancelled."
fi

ORIGINAL_PLIST="$(mktemp -t ImageResizer-Info.plist.XXXXXX)"
cp "$PLIST" "$ORIGINAL_PLIST"
COMMITTED=false
ARTIFACT_DIR=""
cleanup() {
  status=$?
  if (( status != 0 )) && [[ "$COMMITTED" != true ]]; then
    cp "$ORIGINAL_PLIST" "$PLIST"
    print -u2 -- "Restored Resources/Info.plist after the failed release."
  fi
  rm -f "$ORIGINAL_PLIST"
  [[ -z "$ARTIFACT_DIR" ]] || rm -rf "$ARTIFACT_DIR"
}
trap cleanup EXIT

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT_BUILD" "$PLIST"

print -- "Running checks..."
"$ROOT/Scripts/check.sh"

print -- "Building app and DMG..."
"$ROOT/Scripts/package.sh"

[[ -f "$APP/Contents/Info.plist" && -f "$DMG" ]] || fail "The packaged app or DMG is missing."
PACKAGED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
PACKAGED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[[ "$PACKAGED_VERSION" == "$VERSION" && "$PACKAGED_BUILD" == "$NEXT_BUILD" ]] || fail "Packaged version does not match the release."
codesign --verify --deep --strict "$APP"
hdiutil verify "$DMG" >/dev/null

ARTIFACT_DIR="$(mktemp -d -t ImageResizer-release.XXXXXX)"
PUBLIC_DMG="$ARTIFACT_DIR/ImageResizer.dmg"
CHECKSUM_FILE="$ARTIFACT_DIR/ImageResizer.dmg.sha256"
APPCAST_DIR="$ARTIFACT_DIR/appcast"
PUBLIC_REPO_DIR="$ARTIFACT_DIR/public-repo"
SPARKLE_TOOLS="$ROOT/.build-release/artifacts/sparkle/Sparkle/bin"
cp "$DMG" "$PUBLIC_DMG"
CHECKSUM="$(shasum -a 256 "$PUBLIC_DMG" | awk '{print $1}')"
print -r -- "$CHECKSUM  ImageResizer.dmg" > "$CHECKSUM_FILE"

if [[ -n "$NOTES_FILE" ]]; then
  PUBLISH_NOTES="$NOTES_FILE"
else
  PUBLISH_NOTES="$ARTIFACT_DIR/release-notes.md"
  {
    print -- "Image Resizer $VERSION for Apple Silicon Macs running macOS 14 or newer."
    print -- ""
    print -- "Download \`ImageResizer.dmg\`, open it, and drag Image Resizer into Applications."
    print -- ""
    print -- "SHA-256: \`$CHECKSUM\`"
    print -- ""
    print -- "Source: https://github.com/$SOURCE_REPO"
  } > "$PUBLISH_NOTES"
fi

[[ -x "$SPARKLE_TOOLS/generate_appcast" && -x "$SPARKLE_TOOLS/generate_keys" ]] || fail "Sparkle publishing tools are missing."
EMBEDDED_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")"
KEYCHAIN_PUBLIC_KEY="$("$SPARKLE_TOOLS/generate_keys" --account "$SPARKLE_ACCOUNT" -p)"
[[ "$EMBEDDED_PUBLIC_KEY" == "$KEYCHAIN_PUBLIC_KEY" ]] || fail "The Sparkle Keychain key does not match SUPublicEDKey."

print -- "Generating signed Sparkle appcast..."
gh repo clone "$RELEASE_REPO" "$PUBLIC_REPO_DIR" -- --depth 1 >/dev/null
mkdir -p "$APPCAST_DIR"
cp "$PUBLIC_DMG" "$APPCAST_DIR/ImageResizer.dmg"
cp "$PUBLISH_NOTES" "$APPCAST_DIR/ImageResizer.md"
[[ ! -f "$PUBLIC_REPO_DIR/appcast.xml" ]] || cp "$PUBLIC_REPO_DIR/appcast.xml" "$APPCAST_DIR/appcast.xml"
"$SPARKLE_TOOLS/generate_appcast" \
  --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "https://github.com/$RELEASE_REPO/releases/download/$TAG/" \
  --embed-release-notes \
  --maximum-versions 3 \
  -o "$APPCAST_DIR/appcast.xml" \
  "$APPCAST_DIR"
xmllint --noout "$APPCAST_DIR/appcast.xml"
grep -q 'sparkle:edSignature=' "$APPCAST_DIR/appcast.xml" || fail "The appcast update is not signed."
grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST_DIR/appcast.xml" || fail "The appcast version is incorrect."

print -- "Committing and tagging source..."
git add Resources/Info.plist dist
git commit -m "Release $TAG"
git tag -a "$TAG" -m "Image Resizer $VERSION"
COMMITTED=true
git push origin main "refs/tags/$TAG"

print -- "Publishing public release..."
gh release create "$TAG" \
  "$PUBLIC_DMG#Image Resizer for Apple Silicon" \
  "$CHECKSUM_FILE#SHA-256 checksum" \
  --repo "$RELEASE_REPO" \
  --title "Image Resizer $VERSION" \
  --notes-file "$PUBLISH_NOTES" \
  --latest

print -- "Publishing Sparkle appcast..."
cp "$APPCAST_DIR/appcast.xml" "$PUBLIC_REPO_DIR/appcast.xml"
git -C "$PUBLIC_REPO_DIR" add appcast.xml
git -C "$PUBLIC_REPO_DIR" commit -m "Publish appcast for $TAG"
git -C "$PUBLIC_REPO_DIR" push origin main

if [[ "$INSTALL_APP" == true ]]; then
  print -- "Installing local app..."
  mkdir -p "$INSTALL_DIR"
  TARGET_APP="$INSTALL_DIR/Image Resizer.app"
  if pgrep -x ImageResizer >/dev/null 2>&1; then
    pkill -x ImageResizer || true
    for _ in {1..20}; do
      pgrep -x ImageResizer >/dev/null 2>&1 || break
      sleep 0.25
    done
  fi
  STAGED_APP="$INSTALL_DIR/.Image Resizer.installing.app"
  BACKUP_APP="$INSTALL_DIR/.Image Resizer.previous.app"
  rm -rf "$STAGED_APP" "$BACKUP_APP"
  ditto "$APP" "$STAGED_APP"
  [[ ! -e "$TARGET_APP" ]] || mv "$TARGET_APP" "$BACKUP_APP"
  mv "$STAGED_APP" "$TARGET_APP"
  if ! codesign --verify --deep --strict "$TARGET_APP"; then
    rm -rf "$TARGET_APP"
    [[ ! -e "$BACKUP_APP" ]] || mv "$BACKUP_APP" "$TARGET_APP"
    fail "Installed app verification failed; the previous app was restored."
  fi
  rm -rf "$BACKUP_APP"
  open "$TARGET_APP"
fi

print -- "Released Image Resizer $VERSION ($NEXT_BUILD)."
print -- "Public download: https://github.com/$RELEASE_REPO/releases/latest"
