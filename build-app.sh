#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
destination="${1:?Usage: build-app.sh destination.app [official-XIOCBTm.plugin]}"
component="${2:-}"
swift build --package-path "$root" --product EpsonWiFiAssistant
binpath="$(swift build --package-path "$root" --show-bin-path)"
mkdir -p "$destination/Contents/MacOS" "$destination/Contents/Resources/Vendor"
cp "$binpath/EpsonWiFiAssistant" "$destination/Contents/MacOS/"
ditto "$root/Sources/EpsonWiFiAssistant/Resources" "$destination/Contents/Resources"
if [[ -n "$component" ]]; then
  ditto --norsrc --noextattr "$component" "$destination/Contents/Resources/Vendor/XIOCBTm.plugin"
  xattr -dr com.apple.FinderInfo "$destination/Contents/Resources/Vendor/XIOCBTm.plugin" 2>/dev/null || true
  codesign --verify --strict "$destination/Contents/Resources/Vendor/XIOCBTm.plugin"
  codesign -v -R '=anchor apple generic and identifier "com.epson.print.plugin.XIOCBTm" and certificate leaf[subject.OU] = "TXAEAV5RN4"' "$destination/Contents/Resources/Vendor/XIOCBTm.plugin"
fi
cat > "$destination/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>EpsonWiFiAssistant</string>
<key>CFBundleIdentifier</key><string>com.personal.photo1500.wifiassistant</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
<key>CFBundleName</key><string>Epson Legacy Connect</string>
<key>CFBundleDisplayName</key><string>Epson Legacy Connect</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>uk</string></array>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Find and verify your Epson printer on your home network after USB Wi-Fi setup.</string>
<key>NSBonjourServices</key><array><string>_printer._tcp</string><string>_pdl-datastream._tcp</string><string>_ipp._tcp</string></array>
</dict></plist>
PLIST
# Sign our outer bundle while preserving Epson's original nested signature.
xattr -dr com.apple.FinderInfo "$destination" 2>/dev/null || true
codesign --force --sign - "$destination"
codesign --verify --deep --strict "$destination"
printf 'Built %s\n' "$destination"
