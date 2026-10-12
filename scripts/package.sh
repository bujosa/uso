#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
version="1.1.0"
swift build -c release

stage="$(mktemp -d)"
app="$stage/Uso.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/.build/release/Uso" "$app/Contents/MacOS/Uso"
cp "$root/AppIcon/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>Uso</string>
  <key>CFBundleIdentifier</key>
  <string>com.davidbujosa.uso.bar</string>
  <key>CFBundleName</key>
  <string>Uso</string>
  <key>CFBundleDisplayName</key>
  <string>Uso</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${version}</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>LSArchitecturePriority</key>
  <array>
    <string>arm64</string>
  </array>
</dict>
</plist>
EOF
identity="Uso Local"
if ! security find-identity -p codesigning | grep -q "$identity"; then
  "$root/scripts/sign-identity.sh"
fi
hash="$(security find-identity -p codesigning | awk -v name="$identity" -F'"' '$2 == name { print $1 }' | awk '{ print $2; exit }')"
codesign --force --sign "$hash" "$app"
mkdir -p "$root/dist"
rm -rf "$root/dist/Uso.app"
ditto "$app" "$root/dist/Uso.app"
rm -f "$root/dist/Uso-${version}-macOS.zip"
ditto -c -k --keepParent "$root/dist/Uso.app" "$root/dist/Uso-${version}-macOS.zip"
rm -rf "$stage"
echo "$root/dist/Uso-${version}-macOS.zip"
