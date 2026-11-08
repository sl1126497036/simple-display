#!/bin/zsh
# 构建 BetterLite VD.app
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/BetterLite VD.app"
BIN="BetterLiteVD"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

clang -fobjc-arc -O2 -Wall \
    -framework Cocoa -framework CoreGraphics \
    -o "$APP/Contents/MacOS/$BIN" \
    "$DIR"/Sources/*.m

cp "$DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true

echo "built: $APP"
