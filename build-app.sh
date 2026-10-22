#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
destination="${1:?Usage: build-app.sh destination.app [official-XIOCBTm.plugin]}"
component="${2:-}"
final_destination="$destination"
# Assemble a fresh bundle so a previous build cannot leave unsealed vendor files.
staging="$(mktemp -d /private/tmp/epson-connect-build.XXXXXX)"
trap 'rm -rf "$staging"' EXIT
destination="$staging/Epson Legacy Connect.app"
for product in EpsonWiFiAssistant EpsonAirPrintBackend; do
  swift build --package-path "$root" --product "$product"
done
binpath="$(swift build --package-path "$root" --show-bin-path)"
mkdir -p "$destination/Contents/MacOS" "$destination/Contents/Resources/Vendor"
for product in EpsonWiFiAssistant EpsonAirPrintBackend; do
  cp "$binpath/$product" "$destination/Contents/MacOS/"
done
if [[ "${ELC_UNIVERSAL:-0}" == 1 ]]; then
  for architecture in arm64 x86_64; do
    scratch="$root/.build/universal-$architecture"
    for product in EpsonWiFiAssistant EpsonAirPrintBackend; do
      swift build --package-path "$root" --scratch-path "$scratch" --triple "$architecture-apple-macosx13.0" --product "$product"
      arch_bin="$(swift build --package-path "$root" --scratch-path "$scratch" --triple "$architecture-apple-macosx13.0" --show-bin-path)"
      cp "$arch_bin/$product" "$staging/$architecture-$product"
    done
  done
  for product in EpsonWiFiAssistant EpsonAirPrintBackend; do
    lipo -create "$staging/arm64-$product" "$staging/x86_64-$product" -output "$destination/Contents/MacOS/$product"
  done
fi
for product in EpsonWiFiAssistant EpsonAirPrintBackend; do
  strip -S -x "$destination/Contents/MacOS/$product"
done
codesign --force --sign - "$destination/Contents/MacOS/EpsonAirPrintBackend"
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
<key>CFBundleShortVersionString</key><string>2.0.0</string>
<key>CFBundleVersion</key><string>2001</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>uk</string></array>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Find and verify your Epson printer on your home network after USB Wi-Fi setup.</string>
<key>NSBonjourServices</key><array><string>_printer._tcp</string><string>_pdl-datastream._tcp</string><string>_ipp._tcp</string><string>_elc-airprint._tcp</string></array>
</dict></plist>
PLIST
# Sign our outer bundle while preserving Epson's original nested signature.
xattr -dr com.apple.FinderInfo "$destination" 2>/dev/null || true
codesign --force --sign - "$destination"
codesign --verify --deep --strict "$destination"
if [[ -e "$final_destination" ]]; then
  backup="$final_destination.previous-$(uuidgen)"
  mv "$final_destination" "$backup"
  printf 'Previous build preserved at %s\n' "$backup"
fi
mkdir -p "$(dirname "$final_destination")"
mv "$destination" "$final_destination"
printf 'Built %s\n' "$final_destination"
