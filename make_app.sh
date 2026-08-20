#!/bin/bash

# Exit on error
set -e

VERSION="${VERSION:-v1.1.0}"
PACKAGE_FORMAT="${PACKAGE_FORMAT:-auto}"

# A stable Apple-issued signature is required for a distributable build. An
# ad-hoc identity can change how macOS tracks Local Network permission between
# builds, so it is available only through an explicit local-testing opt-in.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
ALLOW_AD_HOC="${ALLOW_AD_HOC:-0}"

if [ -z "$SIGN_IDENTITY" ]; then
    if [ "$ALLOW_AD_HOC" = "1" ]; then
        SIGN_IDENTITY="-"
    else
        echo "ERROR: SIGN_IDENTITY is required."
        echo "Use an Apple-issued identity, for example:"
        echo "  SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./make_app.sh"
        echo "For disposable local testing only, explicitly opt in:"
        echo "  ALLOW_AD_HOC=1 ./make_app.sh"
        exit 2
    fi
fi

if [ "$SIGN_IDENTITY" = "-" ] && [ "$ALLOW_AD_HOC" != "1" ]; then
    echo "ERROR: ad-hoc signing requires ALLOW_AD_HOC=1."
    exit 2
fi

# Apple notarization settings. Leave empty for local ad-hoc builds.
APPLE_ID="${APPLE_ID:-}"
APP_PASSWORD="${APP_PASSWORD:-}"
TEAM_ID="${TEAM_ID:-}"

echo "============================================"
echo "  Building Screen Bridge $VERSION (Universal Binary)"
echo "============================================"
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "WARNING: creating an ad-hoc signed local-test build."
    echo "If shared, label it as an unnotarized self-use/preview build."
    echo "macOS Local Network permission identity may not remain stable between builds."
fi

case "$PACKAGE_FORMAT" in
    auto|dmg|zip) ;;
    *)
        echo "ERROR: PACKAGE_FORMAT must be auto, dmg, or zip."
        exit 2
        ;;
esac

swift build -c release --arch arm64 --arch x86_64

# Define Paths
BUILD_DIR=".build/apple/Products/Release"
APP_NAME="Screen Bridge.app"
DMG_NAME="Screen-Bridge-${VERSION}.dmg"
ZIP_NAME="Screen-Bridge-${VERSION}-macOS-universal.zip"
DMG_STAGING="dmg_staging"

# Clean old artifacts
rm -rf "$APP_NAME" "ScreenBridge.app" "BetterCast.app" "PrivateBetterCast.app" "BetterCastSender.app" "$DMG_STAGING" "$DMG_NAME" "$ZIP_NAME" "Screen Bridge.dmg" "ScreenBridge.dmg" "BetterCast.dmg"

# ============================================
# Screen Bridge App (unified sender + receiver)
# ============================================
echo "Creating $APP_NAME..."
mkdir -p "$APP_NAME/Contents/MacOS"
mkdir -p "$APP_NAME/Contents/Resources"
# Keep the internal Swift package target name for compatibility, but expose the
# product executable under the public Screen Bridge name.
cp "$BUILD_DIR/BetterCastSender" "$APP_NAME/Contents/MacOS/Screen Bridge"
cp "BetterCastSender-Info.plist" "$APP_NAME/Contents/Info.plist"
cp "assets/branding/BetterCastIcon.icns" "$APP_NAME/Contents/Resources/AppIcon.icns"

# This app currently requests no restricted entitlements. Passing an empty
# entitlement plist produces an invalid entitlement blob on some macOS builds,
# which can make TCC and signature diagnostics disagree about the app identity.
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP_NAME"
codesign --verify --deep --strict "$APP_NAME"

PACKAGE_ARTIFACT=""

create_dmg() {
    echo "Creating DMG..."
    mkdir -p "$DMG_STAGING"
    cp -R "$APP_NAME" "$DMG_STAGING/"
    ln -s /Applications "$DMG_STAGING/Applications"

    if hdiutil create -volname "Screen Bridge $VERSION" \
        -srcfolder "$DMG_STAGING" \
        -ov -format UDZO \
        "$DMG_NAME"; then
        rm -rf "$DMG_STAGING"
        echo "Signing DMG..."
        codesign --force --sign "$SIGN_IDENTITY" "$DMG_NAME"
        codesign --verify --strict "$DMG_NAME"
        PACKAGE_ARTIFACT="$DMG_NAME"
        return 0
    fi

    rm -rf "$DMG_STAGING" "$DMG_NAME"
    return 1
}

create_zip() {
    echo "Creating ZIP..."
    ditto -c -k --sequesterRsrc --keepParent "$APP_NAME" "$ZIP_NAME"
    unzip -tq "$ZIP_NAME"
    PACKAGE_ARTIFACT="$ZIP_NAME"
}

if [ "$PACKAGE_FORMAT" = "dmg" ]; then
    create_dmg
elif [ "$PACKAGE_FORMAT" = "zip" ]; then
    create_zip
elif ! create_dmg; then
    echo "WARNING: DMG creation failed; falling back to a verified ZIP."
    create_zip
fi

# ============================================
# Notarize DMG (if Apple ID is set)
# ============================================
if [ -n "$APPLE_ID" ] && [ -n "$APP_PASSWORD" ] && [ -n "$TEAM_ID" ] && [ "$PACKAGE_ARTIFACT" = "$DMG_NAME" ]; then
    echo "Notarizing DMG..."
    xcrun notarytool submit "$DMG_NAME" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$APP_PASSWORD" \
        --wait

    echo "Stapling notarization ticket..."
    xcrun stapler staple "$DMG_NAME"
else
    echo ""
    echo "Skipping notarization (requires a DMG plus APPLE_ID, APP_PASSWORD, and TEAM_ID)"
fi

echo ""
echo "============================================"
echo "  Build Complete!"
echo "============================================"
echo "App:"
echo "  - $APP_NAME (signed: $SIGN_IDENTITY)"
echo "Package:"
echo "  - $PACKAGE_ARTIFACT"
echo ""
echo "Installation:"
if [ "$PACKAGE_ARTIFACT" = "$DMG_NAME" ]; then
    echo "  1. Open the DMG and drag Screen Bridge to Applications"
else
    echo "  1. Unzip the archive and move Screen Bridge.app to Applications"
fi
echo "  2. Grant Screen Recording permission when prompted"
echo "  3. Control the extended display from the Mac keyboard, trackpad, mouse, and clipboard"
