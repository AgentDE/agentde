#!/bin/zsh
# Builds build/<app name>.app (AgentDE unless a brand file renames it; see scripts/brand.sh) with just the
# Command Line Tools (no Xcode): AgentDE plus the native extensions in EXTENSIONS (default extensions.json;
# see scripts/assemble.py). A workspace that builds its own app instead sets APP_PACKAGE (its folder),
# APP_PRODUCT (its app executable) and APP_HELPERS (executables to bundle, from the same package).
# Usage: scripts/build-app.sh [release|debug]
set -euo pipefail
cd "${0:A:h}/.."
source scripts/env.sh
source scripts/brand.sh

CONFIG=${1:-release}
VERSION=$(<VERSION)
BUILD=$(git -C "${APP_PACKAGE:-.}" rev-list --count HEAD 2>/dev/null || echo 1)
APP=build/$APP_NAME.app
HELPERS=()   # "<package dir>\t<product>"
if [[ -n ${APP_PACKAGE:-} ]]; then
  PACKAGE=${APP_PACKAGE:A}
  PRODUCT=${APP_PRODUCT:?set APP_PRODUCT with APP_PACKAGE}
  for helper in ${=APP_HELPERS:-agentde-pty}; do HELPERS+=("$PACKAGE"$'\t'"$helper"); done
else
  PACKAGE=$PWD/.build/app-package
  PRODUCT=AgentDEBuild
  HELPERS=("$PWD"$'\t'agentde-pty ${(f)"$(python3 -I scripts/assemble.py "${EXTENSIONS:-extensions.json}" "$PACKAGE")"})
fi
# ARCHS="arm64 x86_64" builds every executable for each and joins them (a universal app, for a download);
# by default only this Mac's architecture is built.
ARCH_LIST=(${=ARCHS:-})
build_exe() {   # <package dir> <product> <destination>
  local dir=$1 product=$2 dest=$3 slices=() arch
  if (( ${#ARCH_LIST} )); then
    for arch in $ARCH_LIST; do
      swift build -c "$CONFIG" --package-path "$dir" --product "$product" --arch "$arch"
      # Copied aside at once: some build systems put every architecture's product in the same folder.
      slices+=("$dest.$arch")
      cp "$(swift build -c "$CONFIG" --package-path "$dir" --arch "$arch" --show-bin-path)/$product" "$dest.$arch"
      lipo -verify_arch "$arch" "$dest.$arch"
    done
    lipo -create $slices -output "$dest"
    rm -f $slices
  else
    swift build -c "$CONFIG" --package-path "$dir" --product "$product"
    cp "$(swift build -c "$CONFIG" --package-path "$dir" --show-bin-path)/$product" "$dest"
  fi
}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
build_exe "$PACKAGE" "$PRODUCT" "$APP/Contents/MacOS/$APP_NAME"
BIN=$(swift build -c "$CONFIG" --package-path "$PACKAGE" ${ARCH_LIST:+--arch} ${ARCH_LIST[1]:-} --show-bin-path)
cp -R "$BIN/SwiftTerm_SwiftTerm.bundle" "$APP/Contents/Resources/"
for helper in $HELPERS; do
  dir=${helper%%$'\t'*} product=${helper##*$'\t'}
  build_exe "$dir" "$product" "$APP/Contents/MacOS/$product"
done
[[ -f $ICON ]] && cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/AppIcons "$APP/Contents/Resources/"   # the icons Settings offers
# Registering workstreams from an installed app (a download has no checkout): it finds the app it's in.
cp scripts/register-workstream.sh scripts/brand.sh "$APP/Contents/Resources/"
# A brand's own resources (more icons, files its extensions read) join the bundle's.
[[ -n $BRAND_RESOURCES && -d $BRAND_RESOURCES ]] && ditto "$BRAND_RESOURCES" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>AgentDEBrandName</key><string>$APP_NAME</string>
  <key>AgentDEDataFolder</key><string>$DATA_FOLDER</string>
  <key>AgentDEDefaultIcon</key><string>$DEFAULT_ICON</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>The sidebar's Calendar widget shows your next events.</string>
  <key>NSMicrophoneUsageDescription</key><string>Programs in your tabs, such as an agent's voice mode, want to use the microphone.</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict>
</dict>
</plist>
PLIST

# A fixed signing identity keeps macOS privacy permissions across rebuilds (see scripts/setup-signing.sh).
SIGN_ID=${SIGN_ID:-}
if [[ -z $SIGN_ID ]] && [[ $(security find-identity -p codesigning 2>/dev/null || true) == *'"AgentDE Local Signing"'* ]]; then
  SIGN_ID="AgentDE Local Signing"
fi
if [[ -n $SIGN_ID ]]; then
  codesign --force --deep --sign "$SIGN_ID" "$APP"
else
  codesign --force --deep --sign - "$APP"
  echo "Signed ad hoc: macOS will ask for permissions again after each install. Run scripts/setup-signing.sh once to fix that."
fi
echo "Built $PWD/$APP ($VERSION, build $BUILD)"
