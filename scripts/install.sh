#!/bin/zsh
# Builds the app (AgentDE, or a brand's; see scripts/brand.sh) and installs it to /Applications (or
# ~/Applications if /Applications isn't writable), plus a launcher named after it in ~/.local/bin.
# Usage: scripts/install.sh            install or update
#        scripts/install.sh --uninstall remove the app and launcher (keeps ~/.config/<data folder>)
set -euo pipefail
cd "${0:A:h}/.."
source scripts/brand.sh

DEST=/Applications
[[ -w $DEST ]] || DEST=$HOME/Applications
APP=$DEST/$APP_NAME.app
LAUNCHER=$HOME/.local/bin/$COMMAND_NAME

if [[ ${1:-} == --uninstall ]]; then
  rm -rf "$APP" "$LAUNCHER"
  echo "Removed $APP and $LAUNCHER (your state in ~/.config/$DATA_FOLDER is kept)"
  exit 0
fi

./scripts/build-app.sh
mkdir -p "$DEST"
# Replace the bundle in place. A running copy keeps working until you quit it.
rm -rf "$APP.new"
cp -R "build/$APP_NAME.app" "$APP.new"
rm -rf "$APP"
mv "$APP.new" "$APP"
# Refresh Launch Services so Spotlight and the Dock pick up the new icon and version.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true

mkdir -p "${LAUNCHER:h}"
cat > "$LAUNCHER" <<SH
#!/bin/sh
# Opens $APP_NAME (installed by scripts/install.sh).
exec open -a "$APP" "\$@"
SH
chmod +x "$LAUNCHER"

echo "Installed $APP"
echo "Launcher: $LAUNCHER  (run '$COMMAND_NAME' from any terminal)"
