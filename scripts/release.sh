#!/bin/zsh
# Builds the app for Apple silicon and Intel, signs it with a Developer ID, has Apple notarize it, and writes
# dist/<app>-<version>.zip for a GitHub release (plus its SHA-256, for the Homebrew cask).
# Needs a "Developer ID Application" certificate in your keychain and notarytool credentials saved once with
#   xcrun notarytool store-credentials agentde --apple-id <you> --team-id <team>
# Usage: scripts/release.sh            (IDENTITY= and NOTARY_PROFILE= override the defaults)
set -euo pipefail
cd "${0:A:h}/.."
source scripts/brand.sh
IDENTITY=${IDENTITY:-$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}
[[ -n $IDENTITY ]] || { echo "No Developer ID Application certificate in your keychain." >&2; exit 1; }
PROFILE=${NOTARY_PROFILE:-agentde}
APP=build/$APP_NAME.app
VERSION=$(<VERSION)
ZIP=dist/$APP_NAME-$VERSION.zip

ARCHS="arm64 x86_64" SIGN_ID=- scripts/build-app.sh release

# Hardened runtime and a secure timestamp, as notarization requires: helpers first, then the app around them.
for exe in $APP/Contents/MacOS/*(.); do
  [[ ${exe:t} == $APP_NAME ]] && continue
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$exe"
done
codesign --force --options runtime --timestamp --entitlements scripts/release.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep --verbose=1 "$APP"

mkdir -p dist
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
# The ticket goes into the app itself, so it opens without asking Apple even offline; then zip it again.
xcrun stapler staple "$APP"
rm -f "$ZIP"
# No resource forks or extended attributes: Homebrew extracts casks with plain unzip, which would leave their
# ._ files inside the app and break its signature ("damaged"). Checked the way Homebrew unpacks it:
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" "$ZIP"
CHECK=$(mktemp -d)
unzip -qq -o "$ZIP" -d "$CHECK" && codesign --verify --strict --deep "$CHECK/$APP_NAME.app" || { echo "The zip doesn't verify after unzip." >&2; exit 1; }
rm -rf "$CHECK"
spctl --assess --type execute --verbose=2 "$APP"
echo "$ZIP"
shasum -a 256 "$ZIP"
