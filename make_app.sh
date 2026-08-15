#!/bin/bash

# Exit on error
set -e

VERSION="v8"

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
echo "  Building ScreenBridge $VERSION (Universal Binary)"
echo "============================================"
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "WARNING: creating an ad-hoc signed local-test build."
    echo "Do not publish it; macOS Local Network permission identity may not remain stable."
fi
swift build -c release --arch arm64 --arch x86_64

# Define Paths
BUILD_DIR=".build/apple/Products/Release"
APP_NAME="ScreenBridge.app"
DMG_NAME="ScreenBridge.dmg"
DMG_STAGING="dmg_staging"

# Clean old artifacts
rm -rf "$APP_NAME" "BetterCast.app" "PrivateBetterCast.app" "BetterCastSender.app" "$DMG_STAGING" "$DMG_NAME" "BetterCast.dmg"

# ============================================
# ScreenBridge App (unified sender + receiver)
# ============================================
echo "Creating $APP_NAME..."
mkdir -p "$APP_NAME/Contents/MacOS"
mkdir -p "$APP_NAME/Contents/Resources"
# The executable name follows the current Swift package target.
cp "$BUILD_DIR/BetterCastSender" "$APP_NAME/Contents/MacOS/BetterCastSender"
cp "BetterCastSender-Info.plist" "$APP_NAME/Contents/Info.plist"
cp "assets/branding/BetterCastIcon.icns" "$APP_NAME/Contents/Resources/AppIcon.icns"

# Code sign with entitlements
codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" --entitlements "BetterCastSender-Release.entitlements" "$APP_NAME"
codesign --verify --deep --strict "$APP_NAME"

# ============================================
# Create DMG
# ============================================
echo "Creating DMG..."
mkdir -p "$DMG_STAGING"
cp -R "$APP_NAME" "$DMG_STAGING/"

# Create a symlink to /Applications for drag-to-install
ln -s /Applications "$DMG_STAGING/Applications"

# Create DMG from staging folder
hdiutil create -volname "ScreenBridge" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_NAME"

# Clean up staging
rm -rf "$DMG_STAGING"

# Sign the DMG itself (required for Gatekeeper to accept it)
echo "Signing DMG..."
codesign --force --sign "$SIGN_IDENTITY" "$DMG_NAME"
codesign --verify --strict "$DMG_NAME"

# ============================================
# Notarize DMG (if Apple ID is set)
# ============================================
if [ -n "$APPLE_ID" ] && [ -n "$APP_PASSWORD" ] && [ -n "$TEAM_ID" ]; then
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
    echo "Skipping notarization (set APPLE_ID, APP_PASSWORD, and TEAM_ID to enable)"
fi

echo ""
echo "============================================"
echo "  Build Complete!"
echo "============================================"
echo "App:"
echo "  - $APP_NAME (signed: $SIGN_IDENTITY)"
echo "DMG:"
echo "  - $DMG_NAME"
echo ""
echo "Installation:"
echo "  1. Open the DMG and drag ScreenBridge to Applications"
echo "  2. Grant Screen Recording permission when prompted"
echo "  3. Control the extended display from the Mac keyboard, trackpad, mouse, and clipboard"
