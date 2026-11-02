# Shared by the scripts: the SDK to build against.
# Newer Command Line Tools SDKs declare SwiftUI's @State as a macro whose compiler plugin only ships with Xcode,
# so builds use the macOS 26 SDK unless AGENTDE_SDK says otherwise.
export SDKROOT=${AGENTDE_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk}
if [[ ! -d $SDKROOT ]]; then
  echo "Missing SDK at $SDKROOT. Install the Command Line Tools (xcode-select --install) or set AGENTDE_SDK." >&2
  exit 1
fi
