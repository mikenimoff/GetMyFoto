#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(tr -d '\n\r' < VERSION)
BUILD=$(tr -d '\n\r' < BUILD)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid VERSION"; exit 1; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "Invalid BUILD"; exit 1; }
bash scripts/test.sh
mkdir -p .build dist
APP="dist/GetMyFoto.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos13.0" -module-cache-path .build/ModuleCache Sources/*.swift -o ".build/GetMyFoto-$ARCH" -framework AppKit -framework SwiftUI -framework ImageCaptureCore
done
lipo -create .build/GetMyFoto-arm64 .build/GetMyFoto-x86_64 -output "$APP/Contents/MacOS/GetMyFoto"
rm -f .build/GetMyFoto.iconset/icon-1024.png
swift -module-cache-path .build/ModuleCache scripts/make-icon.swift .build/GetMyFoto.iconset
cp .build/GetMyFoto.iconset/icon_512x512@2x.png dist/GetMyFoto-icon.png
iconutil -c icns .build/GetMyFoto.iconset -o "$APP/Contents/Resources/GetMyFoto.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>GetMyFoto</string>
<key>CFBundleIdentifier</key><string>com.mikenimoff.GetMyFoto</string>
<key>CFBundleName</key><string>GetMyFoto</string>
<key>CFBundleDisplayName</key><string>GetMyFoto</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>CFBundleIconFile</key><string>GetMyFoto</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSCameraUsageDescription</key><string>GetMyFoto нужен доступ к подключённому iPhone для переноса и удаления выбранных фото и видео.</string>
<key>NSPhotoLibraryUsageDescription</key><string>GetMyFoto переносит выбранные фото и видео с подключённого iPhone.</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 mikenimoff</string>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/GetMyFoto-$VERSION-macOS-universal.zip"
(cd dist && shasum -a 256 "GetMyFoto-$VERSION-macOS-universal.zip" > SHA256SUMS.txt)
echo "Built GetMyFoto $VERSION ($BUILD) for Apple Silicon and Intel."
