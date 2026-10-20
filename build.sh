#!/bin/zsh
# Builds Chromeless-FullPanelKit.app with Swift Package Manager. No Xcode
# project. The one dependency, FullPanelKit, is fetched from GitHub at the exact
# version pinned in Package.swift / Package.resolved.
#
#   ./build.sh                                   # → ./Chromeless-FullPanelKit.app
#   ./build.sh ~/Downloads/Chromeless-FullPanelKit.app
#   BUNDLE_ID=com.example.chromeless ./build.sh  # override the bundle identifier
set -euo pipefail
cd "${0:a:h}"

APP="${1:-Chromeless-FullPanelKit.app}"
[[ "$APP" == *.app ]] || { echo "output must end in .app: $APP" >&2; exit 2; }
# Separate from upstream Chromeless (com.chromeless.app): its own preferences,
# cookies (~/Library/WebKit/<id>) and installation.
BUNDLE_ID="${BUNDLE_ID:-com.brianmerchant.chromeless-fullpanelkit}"
ARCH="$(uname -m)"

# Never replace a different app (an upstream Chromeless.app, another build).
if [[ -e "$APP" ]]; then
  EXISTING="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$EXISTING" != "$BUNDLE_ID" ]]; then
    echo "refusing to replace $APP (bundle id '${EXISTING:-unknown}', expected $BUNDLE_ID)" >&2
    exit 1
  fi
fi

if [[ ! -f Chromeless.icns ]]; then
  echo "▸ rendering icon"
  rm -rf build/AppIcon.iconset
  mkdir -p build
  swift tools/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o Chromeless.icns
fi

# With Package.resolved present it is authoritative (no silent re-resolution).
PINNED=()
[[ -f Package.resolved ]] && PINNED=(--force-resolved-versions)
echo "▸ resolving packages"
swift package resolve $PINNED

echo "▸ compiling ($ARCH, release)"
swift build -c release --product Chromeless --arch "$ARCH" $PINNED
BIN="$(swift build -c release --arch "$ARCH" --show-bin-path)/Chromeless"
[[ -x "$BIN" ]] || { echo "compiled executable missing: $BIN" >&2; exit 1; }

echo "▸ packaging $APP"
# Assemble in a staging directory, then replace only this bundle.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/chromeless-app.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
BUNDLE="$STAGE/Chromeless.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/Chromeless"
cp Chromeless.icns "$BUNDLE/Contents/Resources/Chromeless.icns"
cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Chromeless</string>
  <key>CFBundleDisplayName</key><string>Chromeless FullPanelKit</string>
  <key>CFBundleExecutable</key><string>Chromeless</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>Chromeless</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>NSHumanReadableCopyright</key><string>chromeless — the browser that isn’t there. Built with FullPanelKit.</string>
</dict>
</plist>
PLIST

# Passkeys require Apple's restricted web-browser.public-key-credential
# entitlement backed by a provisioning profile; macOS SIGKILLs ad-hoc builds
# that claim it. Default: ad-hoc, no entitlement (app hides WebAuthn so sites
# offer fallback sign-in). Once Apple grants the capability to your App ID
# (set BUNDLE_ID to match it):
#   PROVISIONING_PROFILE=chromeless.provisionprofile \
#   CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./build.sh
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  if [[ -n "${PROVISIONING_PROFILE:-}" ]]; then
    cp "$PROVISIONING_PROFILE" "$BUNDLE/Contents/embedded.provisionprofile"
  fi
  codesign --force --sign "$CODESIGN_IDENTITY" --entitlements chromeless.entitlements "$BUNDLE"
  echo "▸ signed as $CODESIGN_IDENTITY with passkey entitlement"
else
  codesign --force --sign - "$BUNDLE" 2>/dev/null
fi

mkdir -p "$(dirname "$APP")"
rm -rf "$APP"
ditto "$BUNDLE" "$APP"
SIZE=$(du -sh "$APP" | cut -f1)
echo "✓ built $APP ($SIZE, $BUNDLE_ID)"
echo "  try:  open $APP"
echo "  or:   $APP/Contents/MacOS/Chromeless --help"
