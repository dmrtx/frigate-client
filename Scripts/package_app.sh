#!/usr/bin/env bash
set -euo pipefail

CONF=${1:-release}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

APP_NAME=${APP_NAME:-FrigateClient}
BUNDLE_ID=${BUNDLE_ID:-app.frigateclient.desktop}
MACOS_MIN_VERSION=${MACOS_MIN_VERSION:-14.0}
MENU_BAR_APP=${MENU_BAR_APP:-1}
SIGNING_MODE=${SIGNING_MODE:-}
APP_IDENTITY=${APP_IDENTITY:-}

if [[ -f "$ROOT/version.env" ]]; then
  source "$ROOT/version.env"
else
  MARKETING_VERSION=${MARKETING_VERSION:-0.1.0}
  BUILD_NUMBER=${BUILD_NUMBER:-1}
fi

ARCH_LIST=( ${ARCHES:-} )
if [[ ${#ARCH_LIST[@]} -eq 0 ]]; then
  HOST_ARCH=$(uname -m)
  ARCH_LIST=("$HOST_ARCH")
fi

for ARCH in "${ARCH_LIST[@]}"; do
  CLANG_MODULE_CACHE_PATH="$ROOT/.build/ModuleCache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/ModuleCache" \
  swift build --build-system native --disable-sandbox --cache-path "$ROOT/.build/cache" \
    --config-path "$ROOT/.build/config" --security-path "$ROOT/.build/security" \
    -c "$CONF" --arch "$ARCH" \
    -Xswiftc -debug-prefix-map -Xswiftc "$ROOT=/Source" \
    -Xswiftc -file-prefix-map -Xswiftc "$ROOT=/Source"
done

# Compile the custom icon at all macOS resolutions.
ICON_SOURCE="$ROOT/Assets/AppIcon.png"
ICON_TARGET="$ROOT/.build/Icon.icns"
if [[ -f "$ICON_SOURCE" && ( ! -f "$ICON_TARGET" || "$ICON_SOURCE" -nt "$ICON_TARGET" ) ]]; then
  "$ROOT/Scripts/build_icon.sh" "$ICON_SOURCE" "$ICON_TARGET"
fi

APP="$ROOT/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

LSUI_VALUE="false"
if [[ "$MENU_BAR_APP" == "1" ]]; then
  LSUI_VALUE="true"
fi

BUILD_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>${MACOS_MIN_VERSION}</string>
    <key>LSUIElement</key><${LSUI_VALUE}/>
    <key>CFBundleIconFile</key><string>Icon</string>
    <key>BuildTimestamp</key><string>${BUILD_TIMESTAMP}</string>
    <key>GitCommit</key><string>${GIT_COMMIT}</string>
    <key>NSLocalNetworkUsageDescription</key><string>Connect to your Frigate server on the local network.</string>
    <key>NSMicrophoneUsageDescription</key><string>Use the microphone for two-way talk with cameras on your configured Frigate server.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <!-- Specific ATS exceptions override the general one and would block native HTTP probes. -->
        <key>NSAllowsArbitraryLoads</key><true/>
    </dict>
</dict>
</plist>
PLIST

build_product_path() {
  local name="$1"
  local arch="$2"
  case "$arch" in
    arm64|x86_64) echo ".build/${arch}-apple-macosx/$CONF/$name" ;;
    *) echo ".build/$CONF/$name" ;;
  esac
}

verify_binary_arches() {
  local binary="$1"; shift
  local expected=("$@")
  local actual
  actual=$(lipo -archs "$binary")
  local actual_count expected_count
  actual_count=$(wc -w <<<"$actual" | tr -d ' ')
  expected_count=${#expected[@]}
  if [[ "$actual_count" -ne "$expected_count" ]]; then
    echo "ERROR: $binary arch mismatch (expected: ${expected[*]}, actual: ${actual})" >&2
    exit 1
  fi
  for arch in "${expected[@]}"; do
    if [[ "$actual" != *"$arch"* ]]; then
      echo "ERROR: $binary missing arch $arch (have: ${actual})" >&2
      exit 1
    fi
  done
}

install_binary() {
  local name="$1"
  local dest="$2"
  local binaries=()
  for arch in "${ARCH_LIST[@]}"; do
    local src
    src=$(build_product_path "$name" "$arch")
    if [[ ! -f "$src" ]]; then
      echo "ERROR: Missing ${name} build for ${arch} at ${src}" >&2
      exit 1
    fi
    binaries+=("$src")
  done
  if [[ ${#ARCH_LIST[@]} -gt 1 ]]; then
    lipo -create "${binaries[@]}" -output "$dest"
  else
    cp "${binaries[0]}" "$dest"
  fi
  chmod +x "$dest"
  verify_binary_arches "$dest" "${ARCH_LIST[@]}"
}

install_binary "$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
if [[ "$CONF" == "release" ]]; then
  strip -S "$APP/Contents/MacOS/$APP_NAME"
fi

# Bundle app resources (if any).
APP_RESOURCES_DIR="$ROOT/Sources/$APP_NAME/Resources"
if [[ -d "$APP_RESOURCES_DIR" ]]; then
  cp -R "$APP_RESOURCES_DIR/." "$APP/Contents/Resources/"
fi

# SwiftPM resource bundles are emitted next to the built binary.
PREFERRED_BUILD_DIR="$(dirname "$(build_product_path "$APP_NAME" "${ARCH_LIST[0]}")")"
SWIFTPM_BUNDLE="${PREFERRED_BUILD_DIR}/${APP_NAME}_${APP_NAME}.bundle"
if [[ -d "$SWIFTPM_BUNDLE" ]]; then
  cp -R "$SWIFTPM_BUNDLE" "$APP/Contents/Resources/"
fi

# Embed frameworks if any exist in the build folder.
FRAMEWORK_DIRS=(".build/$CONF" ".build/${ARCH_LIST[0]}-apple-macosx/$CONF")
for dir in "${FRAMEWORK_DIRS[@]}"; do
  if compgen -G "${dir}/*.framework" >/dev/null; then
    cp -R "${dir}/"*.framework "$APP/Contents/Frameworks/"
    chmod -R a+rX "$APP/Contents/Frameworks"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME"
    break
  fi
done

if [[ -f "$ICON_TARGET" ]]; then
  cp "$ICON_TARGET" "$APP/Contents/Resources/Icon.icns"
fi

# Ensure contents are writable before stripping attributes and signing.
chmod -R u+w "$APP"

# Strip extended attributes to prevent AppleDouble files that break code sealing.
xattr -cr "$APP"
find "$APP" -name '._*' -delete

ENTITLEMENTS_DIR="$ROOT/.build/entitlements"
mkdir -p "$ENTITLEMENTS_DIR"

# Rebuild defaults on every run, including installations with an older cached empty plist.
# Merge into a generated signing file so custom entitlement sources are preserved.
SIGNING_ENTITLEMENTS="$ENTITLEMENTS_DIR/${APP_NAME}-signing.entitlements"
python3 - "${APP_ENTITLEMENTS:-}" "$SIGNING_ENTITLEMENTS" <<'PYTHON'
import plistlib, sys
source, destination = sys.argv[1:]
entitlements = {}
if source:
    with open(source, 'rb') as f:
        entitlements = plistlib.load(f)
entitlements['com.apple.security.device.audio-input'] = True
if entitlements.get('com.apple.security.app-sandbox'):
    entitlements['com.apple.security.device.microphone'] = True
with open(destination, 'wb') as f:
    plistlib.dump(entitlements, f)
PYTHON

if [[ "$SIGNING_MODE" == "adhoc" || -z "$APP_IDENTITY" ]]; then
  CODESIGN_ARGS=(--force --sign "-")
else
  CODESIGN_ARGS=(--force --timestamp --options runtime --sign "$APP_IDENTITY")
fi

# Sign embedded frameworks and their nested binaries before the app bundle.
sign_frameworks() {
  local fw
  for fw in "$APP/Contents/Frameworks/"*.framework; do
    if [[ ! -d "$fw" ]]; then
      continue
    fi
    while IFS= read -r -d '' bin; do
      codesign "${CODESIGN_ARGS[@]}" "$bin"
    done < <(find "$fw" -type f -perm -111 -print0)
    codesign "${CODESIGN_ARGS[@]}" "$fw"
  done
}
sign_frameworks

codesign "${CODESIGN_ARGS[@]}" \
  --entitlements "$SIGNING_ENTITLEMENTS" \
  "$APP"

echo "Created $APP"
