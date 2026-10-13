#!/bin/bash
# Собирает Портовик.app из SwiftPM-пакета.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=release
APP="build/Портовик.app"

echo "→ Компиляция ($CONFIG)…"
swift build -c $CONFIG

echo "→ Сборка бандла…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Portovik" "$APP/Contents/MacOS/Portovik"

# --- иконка -----------------------------------------------------------------
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
RAW=$(mktemp -d)
swift Tools/make_icon.swift "$RAW" >/dev/null
cp "$RAW/icon_16x16.png"     "$ICONSET/icon_16x16.png"
cp "$RAW/icon_32x32.png"     "$ICONSET/icon_16x16@2x.png"
cp "$RAW/icon_32x32.png"     "$ICONSET/icon_32x32.png"
cp "$RAW/icon_64x64.png"     "$ICONSET/icon_32x32@2x.png"
cp "$RAW/icon_128x128.png"   "$ICONSET/icon_128x128.png"
cp "$RAW/icon_256x256.png"   "$ICONSET/icon_128x128@2x.png"
cp "$RAW/icon_256x256.png"   "$ICONSET/icon_256x256.png"
cp "$RAW/icon_512x512.png"   "$ICONSET/icon_256x256@2x.png"
cp "$RAW/icon_512x512.png"   "$ICONSET/icon_512x512.png"
cp "$RAW/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# --- Info.plist -------------------------------------------------------------
cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>Портовик</string>
    <key>CFBundleDisplayName</key>          <string>Портовик</string>
    <key>CFBundleExecutable</key>           <string>Portovik</string>
    <key>CFBundleIdentifier</key>           <string>me.garik.Portovik</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>1.0</string>
    <key>CFBundleVersion</key>              <string>1</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>       <string>14.0</string>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>CFBundleDevelopmentRegion</key>    <string>ru</string>
    <key>NSAppleEventsUsageDescription</key> <string>Чтобы завершать процессы других пользователей с правами администратора.</string>
</dict>
</plist>
PLIST

echo "→ Подпись…"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo "✓ Готово: $APP"
