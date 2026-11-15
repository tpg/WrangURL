#!/usr/bin/env bash
# Builds a Developer ID signed, notarized and stapled WrangURL.app in build/release, packaged as a
# zip (for Sparkle updates) and a DMG (for first installs). .github/workflows/release.yml runs it too.
#
# One-time setup:
#   1. Create a "Developer ID Application" certificate (Xcode → Settings → Accounts →
#      Manage Certificates, or developer.apple.com) and install it in your keychain.
#   2. Store notarization credentials (use an app-specific password from account.apple.com):
#        xcrun notarytool store-credentials WrangURL --apple-id <email> --team-id 3A6RMA5S3D
#
# Usage: scripts/release.sh
#   TEAM_ID         Apple Developer team (default: 3A6RMA5S3D)
#   VERSION         MARKETING_VERSION, e.g. 1.2.3 (default: the one in project.yml)
#   BUILD_NUMBER    CURRENT_PROJECT_VERSION (default: the one in project.yml)
#   NOTARY_PROFILE  notarytool keychain profile (default: WrangURL)
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER
#                   an App Store Connect API key (.p8) to notarize with instead of the profile (CI)
#   SKIP_NOTARIZE=1 build and sign only, e.g. to check signing before notarizing
set -euo pipefail

TEAM_ID="${TEAM_ID:-3A6RMA5S3D}"
NOTARY_PROFILE="${NOTARY_PROFILE:-WrangURL}"
SIGNING_IDENTITY="Developer ID Application"

cd "$(dirname "$0")/.."
OUT="build/release"
ARCHIVE="$OUT/WrangURL.xcarchive"
APP="$OUT/export/WrangURL.app"

step() { printf '\n==> %s\n' "$*"; }

if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    NOTARY_AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
fi
notarize() {
    xcrun notarytool submit "$1" "${NOTARY_AUTH[@]}" --wait --output-format json > "$OUT/notarize.json" || true
    cat "$OUT/notarize.json"
    local id status
    id=$(/usr/bin/plutil -extract id raw "$OUT/notarize.json" 2>/dev/null || true)
    status=$(/usr/bin/plutil -extract status raw "$OUT/notarize.json" 2>/dev/null || true)
    if [[ "$status" != Accepted ]]; then
        [[ -n "$id" ]] && xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" || true
        echo "error: notarization of $1 failed (status: ${status:-unknown})" >&2
        exit 1
    fi
}

# The certificate's SHA-1, for codesign, in case the keychain holds more than one Developer ID.
IDENTITY_HASH=$(security find-identity -v -p codesigning \
    | awk -v name="\"$SIGNING_IDENTITY: " -v team="($TEAM_ID)\"" 'index($0, name) && index($0, team) { print $2; exit }')
if [[ -z "$IDENTITY_HASH" ]]; then
    echo "error: no \"$SIGNING_IDENTITY\" certificate for team $TEAM_ID in the keychain (see setup at the top of this script)" >&2
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

step "Generating Xcode project"
xcodegen generate --quiet

VERSION_SETTINGS=()
[[ -n "${VERSION:-}" ]] && VERSION_SETTINGS+=(MARKETING_VERSION="$VERSION")
[[ -n "${BUILD_NUMBER:-}" ]] && VERSION_SETTINGS+=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")

step "Archiving"
xcodebuild archive -quiet \
    -project WrangURL.xcodeproj \
    -scheme WrangURL \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -skipPackagePluginValidation \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    ${VERSION_SETTINGS[@]+"${VERSION_SETTINGS[@]}"}

step "Exporting"
# Exporting re-signs everything inside the app, Sparkle's helpers included, with the Developer ID.
EXPORT_OPTIONS="$OUT/ExportOptions.plist"
cp scripts/ExportOptions.plist "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$EXPORT_OPTIONS"
xcodebuild -exportArchive -quiet \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath "$OUT/export"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="$OUT/WrangURL-$VERSION.zip"
DMG="$OUT/WrangURL-$VERSION.dmg"

step "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d -r- "$APP" 2>&1 | grep -q "certificate leaf\[subject.OU\] = \"$TEAM_ID\"" \
    || { echo "error: release build isn't signed by team $TEAM_ID" >&2; exit 1; }
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow \
    && { echo "error: release build has the get-task-allow entitlement" >&2; exit 1; }

if [[ "${SKIP_NOTARIZE:-}" == 1 ]]; then
    step "Skipping notarization; signed app at $APP"
    exit 0
fi

step "Notarizing app"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
xcrun stapler staple "$APP"
# Zip the stapled app again, so the ticket travels with it.
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

step "Building DMG"
STAGING="$OUT/dmg"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "WrangURL" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"
codesign --sign "$IDENTITY_HASH" --timestamp "$DMG"

step "Notarizing DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
rm -f "$OUT/notarize.json"

step "Checking Gatekeeper"
spctl --assess --type execute --verbose "$APP"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

step "Done: $ZIP and $DMG"
