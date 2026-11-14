#!/bin/bash
# Assembles a double-clickable Koma Desk.app from the SwiftPM build product.
set -euo pipefail

cd "$(dirname "$0")"

APP="build/Koma Desk.app"
CONTENTS="$APP/Contents"

echo "==> Building release binary"
swift build -c release

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp ".build/release/KomaDesk" "$CONTENTS/MacOS/Koma Desk"
cp "Resources/Info.plist" "$CONTENTS/Info.plist"
cp "Resources/KomaDesk.icns" "$CONTENTS/Resources/KomaDesk.icns"
printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> Signing (ad-hoc)"
# Ad-hoc signing lets the app run on Apple silicon. A downloaded copy is
# still blocked once by Gatekeeper; the README tells people to use
# System Settings → Privacy & Security → Open Anyway.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CONTENTS/Info.plist")
ZIP="build/KomaDesk-${VERSION}.zip"
echo "==> Zipping $ZIP"
rm -f "$ZIP"
# ditto keeps the app bundle intact. Plain zip can break the signature.
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Registering document types with Launch Services"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$(cd "$APP" && pwd)"

echo
echo "Built $(cd "$APP" && pwd)"
echo "Zip:   $(cd "$(dirname "$ZIP")" && pwd)/$(basename "$ZIP")"
echo "Run it with:  open '$(cd "$APP" && pwd)'"
echo "Install it with:  cp -R '$(cd "$APP" && pwd)' /Applications/"
