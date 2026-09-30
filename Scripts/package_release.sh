#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source "$ROOT/version.env"

export ARCHES=${ARCHES:-"arm64 x86_64"}
"$ROOT/Scripts/package_app.sh" release

ARCH_LABEL=${ARCHES// /-}
if [[ "$ARCHES" == "arm64 x86_64" || "$ARCHES" == "x86_64 arm64" ]]; then
  ARCH_LABEL=universal
fi
PACKAGE_NAME="${APP_NAME}-${MARKETING_VERSION}-${ARCH_LABEL}.zip"
mkdir -p "$ROOT/dist"

# Include only the app, without Finder metadata, resource forks, or local settings.
ditto --norsrc --noextattr --noqtn -c -k --keepParent \
  "$ROOT/${APP_NAME}.app" "$ROOT/dist/$PACKAGE_NAME"
cd "$ROOT/dist"
shasum -a 256 "$PACKAGE_NAME" > SHA256SUMS
echo "Created dist/$PACKAGE_NAME and dist/SHA256SUMS"
