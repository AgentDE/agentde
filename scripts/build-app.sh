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
swift build -c "$CONFIG" --package-path "$PACKAGE" --product "$PRODUCT"
BIN=$(swift build -c "$CONFIG" --package-path "$PACKAGE" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/$PRODUCT" "$APP/Contents/MacOS/$APP_NAME"
cp -R "$BIN/SwiftTerm_SwiftTerm.bundle" "$APP/Contents/Resources/"
for helper in $HELPERS; do
  dir=${helper%%$'\t'*} product=${helper##*$'\t'}
  swift build -c "$CONFIG" --package-path "$dir" --product "$product"
  cp "$(swift build -c "$CONFIG" --package-path "$dir" --show-bin-path)/$product" "$APP/Contents/MacOS/$product"
done
[[ -f $ICON ]] && cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/AppIcons "$APP/Contents/Resources/"   # the icons Settings offers
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
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/><key>NSAllowsArbitraryLoads</key><true/></dict>
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
