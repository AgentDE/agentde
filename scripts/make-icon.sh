#!/bin/zsh
# Redraws AgentDE's icon: Resources/AppIcons/agentde.png and the bundle's Resources/AppIcon.icns.
set -euo pipefail
cd "${0:A:h}/.."
swift scripts/make-icon.swift Resources/AppIcons/agentde.png
SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcons/agentde.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) Resources/AppIcons/agentde.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Drew Resources/AppIcons/agentde.png and Resources/AppIcon.icns"
