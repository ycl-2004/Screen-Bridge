#!/bin/bash
set -euo pipefail

VERSION="${VERSION:-v8}"
CONFIGURATION="${CONFIGURATION:-Release}"
PROJECT_PATH="${PROJECT_PATH:-BetterCastIOS.xcodeproj}"
SCHEME="${SCHEME:-BetterCastReceiverIOS}"
EXPORT_OPTIONS_PLIST="${EXPORT_OPTIONS_PLIST:-}"
OUTPUT_IPA="${OUTPUT_IPA:-ScreenBridge-Receiver-iOS-${VERSION}.ipa}"
OVERWRITE="${OVERWRITE:-0}"
ALLOW_PROVISIONING_UPDATES="${ALLOW_PROVISIONING_UPDATES:-0}"

echo "=================================="
echo "  ScreenBridge iOS Archive + Export $VERSION"
echo "=================================="

if [ -z "$EXPORT_OPTIONS_PLIST" ] || [ ! -f "$EXPORT_OPTIONS_PLIST" ]; then
    echo "ERROR: EXPORT_OPTIONS_PLIST must point to an Xcode export-options plist."
    echo "Use method 'debugging' for a Personal/Development Team device install,"
    echo "or the distribution method appropriate for your Apple account."
    echo "Example:"
    echo "  EXPORT_OPTIONS_PLIST=/absolute/path/ExportOptions.plist ./package_ios_ipa.sh"
    exit 2
fi

if [ ! -d "$PROJECT_PATH" ]; then
    echo "ERROR: Xcode project not found: $PROJECT_PATH"
    exit 2
fi

if [ -e "$OUTPUT_IPA" ] && [ "$OVERWRITE" != "1" ]; then
    echo "ERROR: output already exists: $OUTPUT_IPA"
    echo "Move it, choose OUTPUT_IPA, or set OVERWRITE=1."
    exit 2
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yc-cast-ipa.XXXXXX")"
ARCHIVE_PATH="$WORK_DIR/ScreenBridge.xcarchive"
EXPORT_PATH="$WORK_DIR/export"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

ARCHIVE_ARGS=(
    -project "$PROJECT_PATH"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "generic/platform=iOS"
    -archivePath "$ARCHIVE_PATH"
    archive
)

EXPORT_ARGS=(
    -exportArchive
    -archivePath "$ARCHIVE_PATH"
    -exportPath "$EXPORT_PATH"
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"
)

if [ "$ALLOW_PROVISIONING_UPDATES" = "1" ]; then
    ARCHIVE_ARGS+=( -allowProvisioningUpdates -allowProvisioningDeviceRegistration )
    EXPORT_ARGS+=( -allowProvisioningUpdates )
fi

echo "Archiving signed iOS app with Xcode..."
xcodebuild "${ARCHIVE_ARGS[@]}"

echo "Exporting IPA with Xcode..."
xcodebuild "${EXPORT_ARGS[@]}"

EXPORTED_IPAS=( "$EXPORT_PATH"/*.ipa )
if [ "${#EXPORTED_IPAS[@]}" -ne 1 ] || [ ! -f "${EXPORTED_IPAS[0]}" ]; then
    echo "ERROR: Xcode export did not produce exactly one IPA."
    exit 1
fi

cp "${EXPORTED_IPAS[0]}" "$OUTPUT_IPA"
IPA_SIZE="$(du -h "$OUTPUT_IPA" | cut -f1)"

echo ""
echo "Done: $OUTPUT_IPA ($IPA_SIZE)"
echo "The IPA came from an Xcode archive/export flow and retains its embedded"
echo "frameworks, provisioning profile, entitlements, resources, and signature."
