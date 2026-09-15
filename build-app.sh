#!/bin/bash
# Assembles a double-clickable Panels.app from the SwiftPM build product.
set -euo pipefail

cd "$(dirname "$0")"

APP="build/Panels.app"
CONTENTS="$APP/Contents"

echo "==> Building release binary"
swift build -c release

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp ".build/release/Panels" "$CONTENTS/MacOS/Panels"
cp "Resources/Info.plist" "$CONTENTS/Info.plist"
cp "Resources/Panels.icns" "$CONTENTS/Resources/Panels.icns"
printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "==> Signing (ad-hoc)"
# Ad-hoc is enough for a locally built personal app; no sandbox, so Panels can
# read comics from anywhere on disk without entitlement plumbing.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP"

echo "==> Registering document types with Launch Services"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$(cd "$APP" && pwd)"

echo
echo "Built $(cd "$APP" && pwd)"
echo "Run it with:  open '$(cd "$APP" && pwd)'"
echo "Install it with:  cp -R '$(cd "$APP" && pwd)' /Applications/"
