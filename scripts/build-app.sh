#!/bin/bash
# Builds build/Sandalphon.app and build/Sandalphon-<version>.dmg.
#
#   scripts/build-app.sh              build for this Mac's architecture
#   scripts/build-app.sh --install    also copy to /Applications and (re)launch
#   scripts/build-app.sh --universal  Apple silicon + Intel (used for releases)
#   scripts/build-app.sh --notarize   submit the DMG to Apple and staple the ticket
#
# Signing: uses the first "Developer ID Application" identity in the keychain, or $SANDALPHON_SIGN_IDENTITY.
# Without one the app is ad-hoc signed, which works locally but loses the Accessibility grant on every rebuild.
# Notarizing needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (an App Store Connect API key),
# or SANDALPHON_NOTARY_PROFILE (a notarytool keychain profile).
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0; UNIVERSAL=0; NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --universal) UNIVERSAL=1 ;;
    --notarize) NOTARIZE=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

VERSION="$(cat VERSION)"
BUILD="${SANDALPHON_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
REPO="${SANDALPHON_REPO:-IftatBhuiyan/sandalphon}"

ARCHS=()
[[ $UNIVERSAL == 1 ]] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c release --product Sandalphon "${ARCHS[@]}"
BIN="$(swift build -c release --product Sandalphon "${ARCHS[@]}" --show-bin-path)/Sandalphon"
SPARKLE=.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework

APP=build/Sandalphon.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Data" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Sandalphon"
cp Data/unigrams.txt Data/bigrams.txt Data/extra.txt Data/modern.txt Data/display.txt Data/misspellings.txt \
   Data/phrases.txt Data/conv_vocab.txt Data/conv2.bin Data/conv3.bin "$APP/Contents/Resources/Data/"
cp Resources/Sandalphon.icns "$APP/Contents/Resources/Sandalphon.icns"
cp -R "$SPARKLE" "$APP/Contents/Frameworks/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>app.sandalphon.Sandalphon</string>
  <key>CFBundleName</key><string>Sandalphon</string>
  <key>CFBundleDisplayName</key><string>Sandalphon</string>
  <key>CFBundleExecutable</key><string>Sandalphon</string>
  <key>CFBundleIconFile</key><string>Sandalphon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT licensed. Runs entirely on this Mac.</string>
  <key>SUFeedURL</key><string>https://github.com/$REPO/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$(cat Resources/sparkle_public_key.txt)</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>NSServices</key>
  <array><dict>
    <key>NSMenuItem</key><dict><key>default</key><string>Fix Typos with Sandalphon</string></dict>
    <key>NSMessage</key><string>fixTypos</string>
    <key>NSPortName</key><string>Sandalphon</string>
    <key>NSSendTypes</key><array><string>NSStringPboardType</string></array>
    <key>NSReturnTypes</key><array><string>NSStringPboardType</string></array>
  </dict></array>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>app.sandalphon.Sandalphon</string>
    <key>CFBundleURLSchemes</key><array><string>sandalphon</string></array>
  </dict></array>
</dict>
</plist>
PLIST

IDENTITY="${SANDALPHON_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
if [[ -n "$IDENTITY" && "$IDENTITY" != "-" ]]; then
  sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
else
  IDENTITY="-"
  sign() { codesign --force --sign - "$@"; }
fi
# Inside out: Sparkle's helpers, then the framework, then the app.
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$FW/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$FW/XPCServices/Downloader.xpc"
sign "$FW/Autoupdate"
sign "$FW/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --identifier app.sandalphon.Sandalphon "$APP"
codesign --verify --deep --strict "$APP"
echo "built $APP $VERSION ($BUILD), signed: $IDENTITY"

DMG="build/Sandalphon-$VERSION.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/Sandalphon.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname Sandalphon -srcfolder "$STAGE" -format UDZO "$DMG"
rm -rf "$STAGE"
[[ "$IDENTITY" != "-" ]] && codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ $NOTARIZE == 1 ]]; then
  [[ -f "$HOME/.private_keys/appstoreconnect.env" && -z "${ASC_KEY_ID:-}" ]] && source "$HOME/.private_keys/appstoreconnect.env"
  if [[ -n "${ASC_KEY_ID:-}" ]]; then
    xcrun notarytool submit "$DMG" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
  elif [[ -n "${SANDALPHON_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$SANDALPHON_NOTARY_PROFILE" --wait
  else
    echo "no notarization credentials found" >&2; exit 1
  fi
  xcrun stapler staple "$DMG"
fi
echo "built $DMG"

if [[ $INSTALL == 1 ]]; then
  pkill -x Sandalphon 2>/dev/null || true
  rm -rf /Applications/Sandalphon.app
  cp -R "$APP" /Applications/Sandalphon.app
  /System/Library/CoreServices/pbs -update 2>/dev/null || true
  open /Applications/Sandalphon.app
  echo "installed and launched /Applications/Sandalphon.app"
fi
