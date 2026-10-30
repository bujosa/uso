#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
version="1.4.0"
# One universal build. install.sh uses the universal app; the release ships one thin app per chip.
archs=(--arch arm64 --arch x86_64)
swift build -c release "${archs[@]}"
universal="$(swift build -c release "${archs[@]}" --show-bin-path)/Uso"
for arch in arm64 x86_64; do lipo "$universal" -verify_arch "$arch"; done

identity="Uso Local"
if ! security find-identity -p codesigning | grep -q "$identity"; then
  "$root/scripts/sign-identity.sh"
fi
hash="$(security find-identity -p codesigning | awk -v name="$identity" -F'"' '$2 == name { print $1 }' | awk '{ print $2; exit }')"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

# make_app <binary> <directory>: writes a signed <directory>/Uso.app around the binary.
make_app() {
  local app="$2/Uso.app" priority=""
  for arch in arm64 x86_64; do
    if lipo "$1" -verify_arch "$arch" 2>/dev/null; then priority+="    <string>${arch}</string>"$'\n'; fi
  done
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$1" "$app/Contents/MacOS/Uso"
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
${priority}  </array>
</dict>
</plist>
EOF
  codesign --force --sign "$hash" "$app"
}

mkdir -p "$root/dist"
make_app "$universal" "$stage/universal"
rm -rf "$root/dist/Uso.app"
ditto "$stage/universal/Uso.app" "$root/dist/Uso.app"

for chip arch in apple-silicon arm64 intel x86_64; do
  lipo "$universal" -thin "$arch" -output "$stage/Uso-$arch"
  make_app "$stage/Uso-$arch" "$stage/$chip"
  zip="Uso-${version}-macOS-${chip}.zip"
  rm -f "$root/dist/$zip" "$root/dist/$zip.sha256"
  ditto -c -k --keepParent "$stage/$chip/Uso.app" "$root/dist/$zip"
  (cd "$root/dist" && shasum -a 256 "$zip" > "$zip.sha256")
  echo "$root/dist/$zip"
done
