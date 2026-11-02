# Shared by the scripts: what this build is called and where its files go. AgentDE by default; a brand file
# (BRAND=path/to/brand.env, say from `make install BRAND=…`) can rename the build so it installs beside AgentDE
# with its own state, holders, logs and Keychain items. A brand file may set:
#   APP_NAME, BUNDLE_ID, DATA_FOLDER (under ~/.config), DEFAULT_ICON (an AppIcons id), ICON (an .icns),
#   BRAND_RESOURCES (a folder whose contents join Resources: more AppIcons, files its extensions read),
#   SIGN_ID (a code-signing identity; "-" signs ad hoc).
if [[ -n ${BRAND:-} ]]; then
  [[ -f $BRAND ]] || { echo "No brand file at $BRAND" >&2; exit 1; }
  BRAND_DIR=${BRAND:A:h}
  source "$BRAND"
fi
APP_NAME=${APP_NAME:-AgentDE}
BUNDLE_ID=${BUNDLE_ID:-dev.agentde.AgentDE}
DATA_FOLDER=${DATA_FOLDER:-agentde}
DEFAULT_ICON=${DEFAULT_ICON:-agentde}
ICON=${ICON:-Resources/AppIcon.icns}
BRAND_RESOURCES=${BRAND_RESOURCES:-}
COMMAND_NAME=${(L)APP_NAME}
