#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP_BUNDLE=${1:-"$ROOT/FrigateClient.app"}
PLIST="$APP_BUNDLE/Contents/Info.plist"
/usr/bin/plutil -lint "$PLIST"
/usr/bin/codesign --verify --strict "$APP_BUNDLE"
python3 - "$PLIST" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    info = plistlib.load(f)
assert info['NSAppTransportSecurity'] == {'NSAllowsArbitraryLoads': True}, 'ATS must allow native HTTP probes as well as WebKit'
print('PASS: packaged ATS policy')
PY
# Execute production HealthProbe and real WebKit under the exact packaged Info.plist.
CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/frigate-package-check.XXXXXX")
trap 'rm -rf "$CHECK_DIR"' EXIT
CHECK_APP="$CHECK_DIR/FrigateClient.app"
mkdir -p "$CHECK_APP/Contents/MacOS"
cp "$PLIST" "$CHECK_APP/Contents/Info.plist"
EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")
xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Tests/PackageChecks/NetworkProbe.swift" \
  "$ROOT/Sources/FrigateClient/ServerAddress.swift" \
  "$ROOT/Sources/FrigateClient/ServerTrust.swift" \
  "$ROOT/Sources/FrigateClient/HealthProbe.swift" \
  "$ROOT/Sources/FrigateClient/WebSessionCookies.swift" \
  -o "$CHECK_APP/Contents/MacOS/$EXECUTABLE"
codesign --force --sign - "$CHECK_APP"
"$CHECK_APP/Contents/MacOS/$EXECUTABLE"
