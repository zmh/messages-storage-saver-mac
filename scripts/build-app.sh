#!/bin/bash
# Builds the SwiftPM product and assembles + signs "dist/Messages Storage Saver.app".
#
#   scripts/build-app.sh [--debug] [--universal] [--sign IDENTITY | --adhoc] [--install]
#                        [--bundle-id ID] [--version V] [--build N] [--out DIR]
#
# Defaults: release, arm64 only, signed with $APP_SIGN_IDENTITY (also read
# from the git-ignored scripts/signing.local.sh; falls back to ad-hoc with a
# warning when unset or not in the keychain), bundle id
# com.zmhllc.MessagesStorageSaver. Debug builds refuse the live Messages
# store unless MSS_ALLOW_REAL_STORE=1; point them at a fixture:
#   open --env MSS_APP_STORE_DIR=/tmp/mss-fixture "dist/Messages Storage Saver.app"
set -euo pipefail
cd "$(dirname "$0")/.."
# Local signing identities (git-ignored): APP_SIGN_IDENTITY, PKG_SIGN_IDENTITY, NOTARY_PROFILE, NOTARY_TEAM_ID.
[ -f scripts/signing.local.sh ] && . scripts/signing.local.sh

CONFIG=release
INSTALL=0
ARCH_FLAGS=()
SIGN="${APP_SIGN_IDENTITY:-}"
ADHOC=0
BUNDLE_ID="${APP_BUNDLE_ID:-com.zmhllc.MessagesStorageSaver}"
VERSION="${APP_VERSION:-0.1.0}"
BUILD="${APP_BUILD:-$(date +%Y%m%d%H%M)}"
OUT=dist

while [ $# -gt 0 ]; do
  case "$1" in
    --debug) CONFIG=debug ;;
    --universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
    --sign) SIGN="$2"; shift ;;
    --adhoc) ADHOC=1 ;;
    --bundle-id) BUNDLE_ID="$2"; shift ;;
    --version) VERSION="$2"; shift ;;
    --build) BUILD="$2"; shift ;;
    --out) OUT="$2"; shift ;;
    --install) INSTALL=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

APP="$OUT/Messages Storage Saver.app"
PRODUCT=MessagesStorageSaver

echo "▸ swift build -c $CONFIG --product $PRODUCT ${ARCH_FLAGS[*]:-}"
swift build -c "$CONFIG" --product "$PRODUCT" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" --product "$PRODUCT" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
BIN="$BIN_DIR/$PRODUCT"
[ -x "$BIN" ] || { echo "binary not found at $BIN" >&2; exit 1; }

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$PRODUCT"
sed -e "s|__BUNDLE_ID__|$BUNDLE_ID|g" -e "s|__VERSION__|$VERSION|g" -e "s|__BUILD__|$BUILD|g" \
  Packaging/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ ! -f Packaging/AppIcon.icns ]; then
  echo "▸ rendering Packaging/AppIcon.icns"
  swift scripts/make-icon.swift Packaging/AppIcon.icns >/dev/null || echo "  (icon skipped)"
fi
if [ -f Packaging/AppIcon.icns ]; then
  cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$APP/Contents/Info.plist" || true
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# The app must not contain the daemon-control / preference-writing code that
# lives in StorageSaverExperimental (CLI only).
SYMBOLS="$(nm "$APP/Contents/MacOS/$PRODUCT" 2>/dev/null || true)"
if grep -q 'StorageSaverExperimental' <<<"$SYMBOLS"; then
  echo "✗ app binary links StorageSaverExperimental; refusing to package" >&2; exit 1
fi
UNDEFINED="$(nm -u "$APP/Contents/MacOS/$PRODUCT" 2>/dev/null || true)"
if grep -qE '_CFPreferencesSetAppValue|_CFPreferencesSetValue' <<<"$UNDEFINED"; then
  echo "✗ app binary references CFPreferencesSet*; refusing to package" >&2; exit 1
fi
echo "  binary check: no StorageSaverExperimental symbols, no CFPreferencesSet* references"

echo "▸ signing"
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [ "$ADHOC" = 1 ] || [ -z "$SIGN" ] || ! grep -q "$SIGN" <<<"$IDENTITIES"; then
  [ "$ADHOC" = 1 ] || echo "  no usable APP_SIGN_IDENTITY ('${SIGN:-unset}'); signing ad-hoc (Full Disk Access will need re-granting after each rebuild)"
  codesign --force --sign - --entitlements Packaging/MessagesStorageSaver.entitlements "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN" \
    --entitlements Packaging/MessagesStorageSaver.entitlements "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
codesign -dvv "$APP" 2>&1 | grep -E 'Identifier|Authority|TeamIdentifier|Runtime' | sed 's/^/  /' || true

echo "✓ $APP ($CONFIG, $BUNDLE_ID $VERSION ($BUILD))"
if [ "$INSTALL" = 1 ]; then
  # Copy into /Applications (same bundle id and signature, so Full Disk Access
  # and Accessibility grants carry over). A running copy is left alone; quit
  # it from its menu before relaunching.
  ditto "$APP" "/Applications/Messages Storage Saver.app"
  codesign --verify --strict "/Applications/Messages Storage Saver.app" && echo "✓ installed to /Applications/Messages Storage Saver.app"
fi
if [ "$CONFIG" = debug ]; then
  echo "  fixture smoke test:  python3 scripts/make-fixture.py /tmp/mss-fixture && open --env MSS_APP_STORE_DIR=/tmp/mss-fixture \"$APP\""
else
  echo "  launch (live store, you): open \"$APP\""
fi
