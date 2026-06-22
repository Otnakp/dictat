#!/usr/bin/env bash
# Release pipeline per Dictat: archivia, firma Developer ID, notarizza, genera
# l'appcast firmato (EdDSA) e pubblica la GitHub release.
#
# Prerequisito una-tantum (credenziali notarizzazione nel Keychain):
#   xcrun notarytool store-credentials dictat-notary \
#       --apple-id "TUA_APPLE_ID" --team-id C9AQ3WX79D --password "APP_SPECIFIC_PASSWORD"
#
# Uso:  ./scripts/release.sh 1.0.0
set -euo pipefail

VERSION="${1:?Uso: ./scripts/release.sh <versione>  es. 1.0.0}"
SCHEME="Dictat"
APP="Dictat"
TEAM="C9AQ3WX79D"
REPO="Otnakp/dictat"
NOTARY_PROFILE="${NOTARY_PROFILE:-dictat-notary}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DIST="$ROOT/dist"
rm -rf build "$DIST"; mkdir -p "$DIST"

echo "▶︎ Versione $VERSION (CFBundleShortVersionString + CFBundleVersion)"
BUILD_NUM="$(date +%Y%m%d%H%M)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Dictat/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" Dictat/Info.plist

echo "▶︎ Archive…"
xcodebuild -project Dictat.xcodeproj -scheme "$SCHEME" -configuration Release \
  -archivePath "build/$APP.xcarchive" archive

echo "▶︎ Export (Developer ID)…"
xcodebuild -exportArchive -archivePath "build/$APP.xcarchive" \
  -exportPath "build/export" -exportOptionsPlist scripts/ExportOptions.plist
APP_PATH="build/export/$APP.app"

echo "▶︎ Zip + notarizzazione…"
ditto -c -k --keepParent "$APP_PATH" "$DIST/$APP.zip"
xcrun notarytool submit "$DIST/$APP.zip" --keychain-profile "$NOTARY_PROFILE" --wait

echo "▶︎ Staple + zip finale…"
xcrun stapler staple "$APP_PATH"
rm -f "$DIST/$APP.zip"
ditto -c -k --keepParent "$APP_PATH" "$DIST/$APP.zip"

echo "▶︎ Appcast firmato…"
GEN="$(find ~/Library/Developer/Xcode/DerivedData -path '*Sparkle*/bin/generate_appcast' 2>/dev/null | head -1)"
: "${GEN:?generate_appcast non trovato — apri il progetto in Xcode per risolvere Sparkle}"
"$GEN" --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" "$DIST"

echo "▶︎ GitHub release…"
gh release create "v$VERSION" "$DIST/$APP.zip" "$DIST/appcast.xml" \
  --repo "$REPO" --title "Dictat $VERSION" --notes "Dictat $VERSION"

echo "✅ Pubblicato. Feed Sparkle: https://github.com/$REPO/releases/latest/download/appcast.xml"
