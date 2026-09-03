#!/bin/bash
# Build, sign, (optionally) notarize, and package a release DMG for Clipen.
#
# Usage (from the repo root):
#   ./dist/release.sh              # build + sign + DMG, skip notarization
#   ./dist/release.sh --notarize   # build + sign + notarize + staple + DMG
#
# Version/build number come straight from the Xcode project
# (MARKETING_VERSION / CURRENT_PROJECT_VERSION) — bump those in Xcode
# before running this. Sparkle compares CURRENT_PROJECT_VERSION, so it
# must increase on every release or existing installs won't see the
# update as newer.
#
# After this script finishes, see SPARKLE.md for the appcast/upload
# steps — this script only produces the local, notarized DMG.

set -euo pipefail

PROJECT="paste.xcodeproj"
SCHEME="paste"
TEAM_ID="VPGVF647K2"
SIGN_IDENTITY="Developer ID Application: Vamshi Krishna Pinni (VPGVF647K2)"
NOTARY_PROFILE="clipen-notary"
APP_NAME="Clipen"

DO_NOTARIZE=0
for arg in "$@"; do
    case "$arg" in
        --notarize) DO_NOTARIZE=1 ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: $0 [--notarize]" >&2
            exit 1
            ;;
    esac
done

cd "$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -f "$PROJECT/project.pbxproj" ]; then
    echo "error: $PROJECT not found — run this from the repo root (or as ./dist/release.sh)" >&2
    exit 1
fi

if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "error: signing identity not found in Keychain:" >&2
    echo "  $SIGN_IDENTITY" >&2
    echo "Run: security find-identity -v -p codesigning" >&2
    exit 1
fi

if [ "$DO_NOTARIZE" = "1" ] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "error: no notarization credentials stored under profile '$NOTARY_PROFILE'" >&2
    echo "Run: xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <your-apple-id> --team-id $TEAM_ID" >&2
    exit 1
fi

BUILD_SETTINGS=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null)
VERSION=$(awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}' <<<"$BUILD_SETTINGS")
BUILD=$(awk -F' = ' '/ CURRENT_PROJECT_VERSION /{print $2; exit}' <<<"$BUILD_SETTINGS")

if [ -z "$VERSION" ] || [ -z "$BUILD" ]; then
    echo "error: couldn't read MARKETING_VERSION/CURRENT_PROJECT_VERSION from $PROJECT" >&2
    exit 1
fi

DIST_DIR="dist"
ARCHIVE_PATH="$DIST_DIR/${APP_NAME}.xcarchive"
EXPORT_DIR="$DIST_DIR/export-${VERSION}.${BUILD}"
DMG_SRC_DIR="$DIST_DIR/dmg-src"
DMG_NAME="${APP_NAME}-${VERSION}.${BUILD}.dmg"
NOTARIZE_ZIP_NAME="${APP_NAME}-${VERSION}.${BUILD}-notarize.zip"
APP_PATH="$EXPORT_DIR/${APP_NAME}.app"

echo "== $APP_NAME $VERSION ($BUILD) =="
mkdir -p "$DIST_DIR"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"

# A public release is exactly the wrong place to trust xcodebuild's
# incremental build database. It has already reported "BUILD SUCCEEDED"
# once this session while silently skipping the app target entirely — a
# corrupted XCBuildData/build.db from a concurrent build elsewhere left it
# believing the target was already up to date, and it shipped a stale
# binary with a straight face. `clean` before every archive costs a couple
# of minutes; a beta built from stale sources costs a lot more to notice.
echo "-- cleaning (never trust incremental state for a public release) --"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release clean

echo "-- archiving --"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    archive

echo "-- exporting --"
# Not using `xcodebuild -exportArchive`: paste.entitlements declares
# com.apple.application-identifier (a provisioning-profile-only
# entitlement, harmless for a non-sandboxed Developer ID app but it makes
# -exportArchive's validation insist on a profile this app doesn't use or
# need). The archive step above already produces a fully Developer-ID
# signed .app, so just take it straight out of the archive.
mkdir -p "$EXPORT_DIR"
ditto "$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app" "$APP_PATH"

if [ ! -d "$APP_PATH" ]; then
    echo "error: expected signed app not found in archive at $APP_PATH" >&2
    exit 1
fi

# Sparkle.framework ships its embedded helpers (Autoupdate, Updater.app,
# the XPC services) signed by Sparkle's own build, not ours — notarization
# rejects them ("not signed with a valid Developer ID certificate", "no
# secure timestamp"). Re-sign bottom-up: nested executables/bundles first,
# then the framework, then the outer app again (its seal covers the
# framework's bytes, so it goes stale the moment those change).
echo "-- re-signing Sparkle's embedded helpers --"
SPARKLE_VERSIONED="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/Current"
codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" \
    "$SPARKLE_VERSIONED/Autoupdate"
codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" \
    "$SPARKLE_VERSIONED/Updater.app/Contents/MacOS/Updater"
codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" \
    "$SPARKLE_VERSIONED/Updater.app"
codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" \
    "$SPARKLE_VERSIONED/XPCServices/Downloader.xpc"
codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" \
    "$SPARKLE_VERSIONED/XPCServices/Installer.xpc"
codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" \
    "$APP_PATH/Contents/Frameworks/Sparkle.framework"
codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" \
    --entitlements "paste/paste.entitlements" \
    "$APP_PATH"

codesign --verify --deep --strict "$APP_PATH"

if [ "$DO_NOTARIZE" = "1" ]; then
    echo "-- notarizing (this can take several minutes) --"
    ditto -c -k --keepParent "$APP_PATH" "$DIST_DIR/$NOTARIZE_ZIP_NAME"
    xcrun notarytool submit "$DIST_DIR/$NOTARIZE_ZIP_NAME" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait
    echo "-- stapling --"
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
else
    echo "-- skipping notarization (pass --notarize to notarize + staple) --"
fi

echo "-- building DMG --"
rm -rf "$DMG_SRC_DIR"
mkdir -p "$DMG_SRC_DIR"
ditto "$APP_PATH" "$DMG_SRC_DIR/${APP_NAME}.app"
ln -s /Applications "$DMG_SRC_DIR/Applications"

rm -f "$DIST_DIR/$DMG_NAME"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_SRC_DIR" -ov -format UDZO "$DIST_DIR/$DMG_NAME"
rm -rf "$DMG_SRC_DIR"

# The website's download button (public/clipen.html, clipen-website repo) is
# hardcoded to releases/latest/download/Clipen.dmg — a plain, unversioned
# filename, on purpose, so the site's link text never has to change between
# releases. GitHub's /latest/download/<name> only works when a release
# actually HAS an asset with that exact name — the versioned DMG above never
# matches it. Every release must therefore upload both filenames.
#
# This bit us for real: the DMG naming switched to versioned filenames
# without this copy existing, and the website's download button silently
# 404'd for every visitor for about 10 days (2026-08-22 to 2026-09-01)
# before anyone noticed download counts had collapsed. This unconditional
# copy, plus the reminder in "Next" below, is what stops that recurring.
PLAIN_DMG_NAME="${APP_NAME}.dmg"
cp -f "$DIST_DIR/$DMG_NAME" "$DIST_DIR/$PLAIN_DMG_NAME"

echo
echo "== done =="
echo "DMG:            $DIST_DIR/$DMG_NAME"
echo "DMG (for site): $DIST_DIR/$PLAIN_DMG_NAME  (identical bytes — same file, plain name for the website link)"
if [ "$DO_NOTARIZE" != "1" ]; then
    echo "(not notarized — re-run with --notarize before shipping this)"
fi
echo
echo "Next (see SPARKLE.md):"
echo "  1. Refresh the appcast:"
echo "     GEN=\$(find ~/Library/Developer/Xcode/DerivedData -path '*SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast' 2>/dev/null | head -1)"
echo "     \"\$GEN\" --download-url-prefix \"https://github.com/pinni-vamshi/clipen-releases/releases/download/v${VERSION}/\" $DIST_DIR/"
echo "  2. Create a GitHub Release tagged v${VERSION} on clipen-releases, upload BOTH:"
echo "       $DIST_DIR/$DMG_NAME        (versioned — this is what the appcast's <enclosure> must point to)"
echo "       $DIST_DIR/$PLAIN_DMG_NAME  (plain \"$PLAIN_DMG_NAME\" — this is what the website's download button needs; do not skip it)"
echo "  3. Commit the regenerated $DIST_DIR/appcast.xml to clipen-releases' main branch"
echo "  4. Verify the site's actual link still resolves (200, not 404):"
echo "     curl -sIL \"https://github.com/pinni-vamshi/clipen-releases/releases/latest/download/${PLAIN_DMG_NAME}\" | head -1"
