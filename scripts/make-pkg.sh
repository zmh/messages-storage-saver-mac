#!/bin/bash
# Notarizes the app and wraps it for distribution.
#
#   scripts/make-pkg.sh [--format auto|dmg|pkg|zip] [--notary-profile NAME]
#                       [--skip-notarize] [--version V]
#
# auto = pkg when a "Developer ID Installer" identity is in the keychain,
# otherwise dmg. Notarization uses `xcrun notarytool` with a keychain profile
# created once, by you:
#   xcrun notarytool store-credentials mss-notary --apple-id <id> --team-id <team id>
# Identities come from APP_SIGN_IDENTITY / PKG_SIGN_IDENTITY (or the
# git-ignored scripts/signing.local.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f scripts/signing.local.sh ] && . scripts/signing.local.sh

FORMAT=auto
PROFILE="${NOTARY_PROFILE:-mss-notary}"
NOTARIZE=1
VERSION="${APP_VERSION:-0.1.0}"
APP_IDENTITY="${APP_SIGN_IDENTITY:?set APP_SIGN_IDENTITY (Developer ID Application) or create scripts/signing.local.sh}"
INSTALLER_IDENTITY="${PKG_SIGN_IDENTITY:-}"
BUNDLE_ID="${APP_BUNDLE_ID:-com.zmhllc.MessagesStorageSaver}"

while [ $# -gt 0 ]; do
  case "$1" in
    --format) FORMAT="$2"; shift ;;
    --notary-profile) PROFILE="$2"; shift ;;
    --skip-notarize) NOTARIZE=0 ;;
    --version) VERSION="$2"; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

APP="dist/Messages Storage Saver.app"
NAME="MessagesStorageSaver-$VERSION"
[ -d "$APP" ] || scripts/build-app.sh --version "$VERSION"

# (grep -q under pipefail can fail on SIGPIPE, so capture first.)
SIGNATURE="$(codesign -dvv "$APP" 2>&1 || true)"
if ! grep -q "Developer ID Application" <<<"$SIGNATURE"; then
  echo "✗ $APP is not signed with a Developer ID Application certificate; notarization would fail." >&2
  echo "  Rebuild with scripts/build-app.sh once the certificate is in the keychain." >&2
  exit 1
fi

IDENTITIES="$(security find-identity -v 2>/dev/null || true)"
if [ "$FORMAT" = auto ]; then
  if grep -q "Developer ID Installer" <<<"$IDENTITIES"; then FORMAT=pkg; else FORMAT=dmg; fi
  echo "▸ format: $FORMAT"
fi

notarize() {  # file
  [ "$NOTARIZE" = 1 ] || { echo "  (notarization skipped)"; return 0; }
  if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "✗ no notarytool keychain profile '$PROFILE'. Create it once with:" >&2
    echo "    xcrun notarytool store-credentials $PROFILE --apple-id <apple id> --team-id ${NOTARY_TEAM_ID:-<team id>}" >&2
    exit 1
  fi
  echo "▸ notarizing $1"
  local log; log="$(mktemp)"
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1 | tee "$log" || true
  if ! grep -q "status: Accepted" "$log"; then
    local id; id="$(grep -m1 '  id: ' "$log" | awk '{print $2}')"
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" || true
    echo "✗ notarization failed" >&2; exit 1
  fi
}

# 1. The app itself.
rm -f "dist/$NAME-app.zip"
ditto -c -k --keepParent "$APP" "dist/$NAME-app.zip"
notarize "dist/$NAME-app.zip"
[ "$NOTARIZE" = 1 ] && xcrun stapler staple "$APP"
rm -f "dist/$NAME-app.zip"

# 2. The container.
case "$FORMAT" in
  pkg)
    [ -n "$INSTALLER_IDENTITY" ] && grep -q "$INSTALLER_IDENTITY" <<<"$IDENTITIES" || { echo "✗ PKG_SIGN_IDENTITY (Developer ID Installer) unset or not in keychain" >&2; exit 1; }
    rm -f dist/component.pkg "dist/$NAME.pkg"
    pkgbuild --component "$APP" --install-location /Applications --identifier "$BUNDLE_ID" --version "$VERSION" dist/component.pkg
    sed -e "s|__BUNDLE_ID__|$BUNDLE_ID|g" -e "s|__VERSION__|$VERSION|g" Packaging/Distribution.xml > dist/Distribution.xml
    productbuild --distribution dist/Distribution.xml --resources Packaging --package-path dist \
      --sign "$INSTALLER_IDENTITY" --timestamp "dist/$NAME.pkg"
    rm -f dist/component.pkg dist/Distribution.xml
    notarize "dist/$NAME.pkg"
    [ "$NOTARIZE" = 1 ] && xcrun stapler staple "dist/$NAME.pkg"
    spctl --assess --type install --verbose "dist/$NAME.pkg" 2>&1 | sed 's/^/  /' || true
    OUTFILE="dist/$NAME.pkg"
    ;;
  dmg)
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f "dist/$NAME.dmg"
    hdiutil create -volname "Messages Storage Saver" -srcfolder "$STAGE" -ov -format UDZO "dist/$NAME.dmg" >/dev/null
    rm -rf "$STAGE"
    codesign --force --sign "$APP_IDENTITY" --timestamp "dist/$NAME.dmg"
    notarize "dist/$NAME.dmg"
    [ "$NOTARIZE" = 1 ] && xcrun stapler staple "dist/$NAME.dmg"
    OUTFILE="dist/$NAME.dmg"
    ;;
  zip)
    rm -f "dist/$NAME.zip"
    ditto -c -k --keepParent "$APP" "dist/$NAME.zip"
    OUTFILE="dist/$NAME.zip"
    ;;
  *) echo "unknown format $FORMAT" >&2; exit 2 ;;
esac

spctl --assess --type execute --verbose "$APP" 2>&1 | sed 's/^/  /' || true
[ "$NOTARIZE" = 1 ] && [ "$FORMAT" != zip ] && xcrun stapler validate "$OUTFILE" | sed 's/^/  /'
echo "✓ $OUTFILE"
