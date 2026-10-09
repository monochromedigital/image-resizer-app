#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PLIST="$ROOT/Resources/Info.plist"
APP="$ROOT/dist/Image Resizer.app"
DMG="$ROOT/dist/Image Resizer.dmg"
SITE_REPO="${SITE_REPO:-monochromedigital/image-resizer-site}"
RELEASE_REPO="monochromedigital/image-resizer-releases"

fail() {
  print -u2 -- "Automated release stopped: $*"
  exit 1
}

[[ -n "${RELEASE_REPO_TOKEN:-}" ]] || fail "RELEASE_REPO_TOKEN is not configured."
[[ -n "${SPARKLE_PRIVATE_KEY:-}" ]] || fail "SPARKLE_PRIVATE_KEY is not configured."
[[ -n "${GITHUB_RUN_NUMBER:-}" ]] || fail "This script must run in GitHub Actions."
[[ "$(uname -m)" == "arm64" ]] || fail "The release runner must use Apple Silicon."

for command in git gh xmllint shasum hdiutil codesign; do
  command -v "$command" >/dev/null || fail "Required command is missing: $command"
done

export GH_TOKEN="$RELEASE_REPO_TOKEN"
SOURCE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
LATEST_TAG="$(gh release list --repo "$RELEASE_REPO" --limit 1 --json tagName --jq '.[0].tagName // ""')"
LATEST_VERSION="${LATEST_TAG#v}"

typeset -a source_parts latest_parts
source_parts=( ${(s:.:)SOURCE_VERSION} )
(( ${#source_parts} == 3 )) || fail "Invalid source version: $SOURCE_VERSION"
BASE_VERSION="$SOURCE_VERSION"

if [[ -n "$LATEST_TAG" ]]; then
  [[ "$LATEST_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "Invalid latest public version: $LATEST_TAG"
  latest_parts=( ${(s:.:)LATEST_VERSION} )
  for index in 1 2 3; do
    if (( latest_parts[index] > source_parts[index] )); then
      BASE_VERSION="$LATEST_VERSION"
      break
    elif (( latest_parts[index] < source_parts[index] )); then
      break
    fi
  done
fi

typeset -a base_parts
base_parts=( ${(s:.:)BASE_VERSION} )
VERSION="${base_parts[1]}.${base_parts[2]}.$(( base_parts[3] + 1 ))"
TAG="v$VERSION"
BUILD=$(( base_parts[1] * 1000000 + base_parts[2] * 1000 + base_parts[3] + 1 ))

print -- "Creating Image Resizer $VERSION ($BUILD) from ${GITHUB_SHA:-HEAD}."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"

"$ROOT/Scripts/check.sh"
"$ROOT/Scripts/package.sh"
codesign --verify --deep --strict "$APP"
hdiutil verify "$DMG" >/dev/null

ARTIFACT_DIR="$(mktemp -d -t ImageResizer-ci-release.XXXXXX)"
KEY_FILE="$(mktemp -t ImageResizer-Sparkle-key.XXXXXX)"
PUBLIC_DMG="$ARTIFACT_DIR/ImageResizer.dmg"
CHECKSUM_FILE="$ARTIFACT_DIR/ImageResizer.dmg.sha256"
NOTES_FILE="$ARTIFACT_DIR/ImageResizer.md"
APPCAST_DIR="$ARTIFACT_DIR/appcast"
PUBLIC_REPO_DIR="$ARTIFACT_DIR/public-repo"
SPARKLE_TOOLS="$ROOT/.build-release/artifacts/sparkle/Sparkle/bin"
RELEASE_CREATED=false

cleanup() {
  status=$?
  if (( status != 0 )) && [[ "$RELEASE_CREATED" == true ]]; then
    print -u2 -- "Rolling back the incomplete public release $TAG."
    gh release delete "$TAG" --repo "$RELEASE_REPO" --cleanup-tag --yes >/dev/null 2>&1 || true
  fi
  rm -f "$KEY_FILE"
  rm -rf "$ARTIFACT_DIR"
}
trap cleanup EXIT

cp "$DMG" "$PUBLIC_DMG"
CHECKSUM="$(shasum -a 256 "$PUBLIC_DMG" | awk '{print $1}')"
print -r -- "$CHECKSUM  ImageResizer.dmg" > "$CHECKSUM_FILE"
{
  print -- "Image Resizer $VERSION for Apple Silicon and Intel Macs running macOS 14 or newer."
  print -- ""
  print -- "Built automatically from source commit \`${GITHUB_SHA:-unknown}\`."
  print -- ""
  print -- "Download \`ImageResizer.dmg\`, open it, and drag Image Resizer into Applications."
  print -- ""
  print -- "SHA-256: \`$CHECKSUM\`"
} > "$NOTES_FILE"

gh auth setup-git
gh repo clone "$RELEASE_REPO" "$PUBLIC_REPO_DIR" -- --depth 1 >/dev/null
mkdir -p "$APPCAST_DIR"
cp "$PUBLIC_DMG" "$APPCAST_DIR/ImageResizer.dmg"
cp "$NOTES_FILE" "$APPCAST_DIR/ImageResizer.md"
[[ ! -f "$PUBLIC_REPO_DIR/appcast.xml" ]] || cp "$PUBLIC_REPO_DIR/appcast.xml" "$APPCAST_DIR/appcast.xml"

[[ -x "$SPARKLE_TOOLS/generate_appcast" ]] || fail "Sparkle publishing tools are missing."
print -rn -- "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"
chmod 600 "$KEY_FILE"
"$SPARKLE_TOOLS/generate_appcast" \
  --ed-key-file "$KEY_FILE" \
  --download-url-prefix "https://github.com/$RELEASE_REPO/releases/download/$TAG/" \
  --embed-release-notes \
  --maximum-versions 3 \
  -o "$APPCAST_DIR/appcast.xml" \
  "$APPCAST_DIR"
xmllint --noout "$APPCAST_DIR/appcast.xml"
grep -q 'sparkle:edSignature=' "$APPCAST_DIR/appcast.xml" || fail "The appcast update is not signed."
grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST_DIR/appcast.xml" || fail "The appcast version is incorrect."

gh release create "$TAG" \
  "$PUBLIC_DMG#Image Resizer (Universal)" \
  "$CHECKSUM_FILE#SHA-256 checksum" \
  --repo "$RELEASE_REPO" \
  --title "Image Resizer $VERSION" \
  --notes-file "$NOTES_FILE" \
  --latest
RELEASE_CREATED=true

cp "$APPCAST_DIR/appcast.xml" "$PUBLIC_REPO_DIR/appcast.xml"
git -C "$PUBLIC_REPO_DIR" config user.name "github-actions[bot]"
git -C "$PUBLIC_REPO_DIR" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git -C "$PUBLIC_REPO_DIR" add appcast.xml
git -C "$PUBLIC_REPO_DIR" commit -m "Publish appcast for $TAG"
git -C "$PUBLIC_REPO_DIR" push origin main
RELEASE_CREATED=false

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git tag -a "$TAG" "${GITHUB_SHA:-HEAD}" -m "Image Resizer $VERSION"
git push origin "refs/tags/$TAG"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    print -- "## Released Image Resizer $VERSION"
    print -- ""
    print -- "- Build: $BUILD"
    print -- "- Source: \`${GITHUB_SHA:-unknown}\`"
    print -- "- Public release: https://github.com/$RELEASE_REPO/releases/tag/$TAG"
  } >> "$GITHUB_STEP_SUMMARY"
fi

# Tell the website a release happened, so its stated version follows within the minute
# rather than waiting for that repository's nightly check. Deliberately best-effort: the
# release is already published and tagged by this point, and a website that is a few
# hours behind is not a reason to fail a release that succeeded.
if [[ -n "${SITE_REPO_TOKEN:-}" ]]; then
  # GH_TOKEN is the release repository's token at this point, which has no access to
  # the site repository, so the call needs its own.
  if GH_TOKEN="$SITE_REPO_TOKEN" gh api "repos/$SITE_REPO/dispatches" \
      --method POST \
      --field event_type=app-released \
      --raw-field "client_payload[version]=$VERSION" \
      --silent 2>/dev/null; then
    print -- "Notified $SITE_REPO of $VERSION."
  else
    print -- "Could not notify $SITE_REPO; its scheduled check will catch up."
  fi
else
  print -- "SITE_REPO_TOKEN is not set; skipping the website notification."
fi

print -- "Released Image Resizer $VERSION ($BUILD)."
