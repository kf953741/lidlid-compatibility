#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
APP="${1:-$ROOT/dist/LidLid Compatibility.app}"
VERIFY_ARGS=()
[[ "${LIDLID_RELEASE:-0}" == "1" ]] && VERIFY_ARGS+=(--release)
[[ "${LIDLID_REQUIRE_NOTARIZATION:-0}" == "1" ]] && VERIFY_ARGS+=(--notarized)
python3 "$ROOT/scripts/verify-compatibility.py" "${VERIFY_ARGS[@]}" "$APP"
MAIN_ARCH="$(lipo -archs "$APP/Contents/MacOS/LidLidCompatibility" | tr ' ' '\n' | sort | xargs)"
DAEMON_ARCH="$(lipo -archs "$APP/Contents/Library/HelperTools/LidLidSleepService" | tr ' ' '\n' | sort | xargs)"
[[ "$MAIN_ARCH" == "$DAEMON_ARCH" ]] || { print -u2 -- "Architecture mismatch: app=$MAIN_ARCH daemon=$DAEMON_ARCH"; exit 1; }
case "$MAIN_ARCH" in
    "arm64 x86_64") ARCH_LABEL="universal" ;;
    "arm64"|"x86_64") ARCH_LABEL="$MAIN_ARCH" ;;
    *) print -u2 -- "Unsupported architecture set: $MAIN_ARCH"; exit 1 ;;
esac
STAGE="$(mktemp -d "$ROOT/.build/compatibility-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/LidLid Compatibility.app"
ln -s /Applications "$STAGE/Applications"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="${LIDLID_COMPATIBILITY_DMG_PATH:-$ROOT/dist/LidLid-Compatibility-$VERSION-macOS-$ARCH_LABEL.dmg}"
hdiutil create -ov -format UDZO -srcfolder "$STAGE" -volname 'LidLid Compatibility' "$DMG"
if [[ -n "${LIDLID_CODE_SIGN_IDENTITY:-}" && "$LIDLID_CODE_SIGN_IDENTITY" != "-" ]]; then
    codesign --force --timestamp --sign "$LIDLID_CODE_SIGN_IDENTITY" "$DMG"
fi
hdiutil verify "$DMG"
print -r -- "$DMG"
