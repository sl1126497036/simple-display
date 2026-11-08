#!/bin/zsh
# 构建 Simple Display.app
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/Simple Display.app"
BIN="SimpleDisplay"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

clang -fobjc-arc -O2 -Wall \
    -framework Cocoa -framework CoreGraphics -framework ServiceManagement -framework IOKit \
    -o "$APP/Contents/MacOS/$BIN" \
    "$DIR"/Sources/*.m

cp "$DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true

echo "built: $APP"
