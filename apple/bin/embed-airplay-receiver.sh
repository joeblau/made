#!/bin/bash
set -euo pipefail
APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$APPLE_ROOT/Packages/AirPlayReceiver"
"$APPLE_ROOT/bin/build-airplay-receiver.sh"
APP="$TARGET_BUILD_DIR/$WRAPPER_NAME"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/AirPlay/Sources"
cp "$PACKAGE/.build/CockpitAirPlayReceiver" "$APP/Contents/MacOS/CockpitAirPlayReceiver"
# Bundle complete corresponding source, including the local adapter/build recipe,
# so recipients can rebuild or modify/relink the separately licensed helper.
cp "$PACKAGE/.build/downloads/"* "$APP/Contents/Resources/AirPlay/Sources/"
cp "$PACKAGE/main.cpp" "$PACKAGE/bounds.patch" "$PACKAGE/tests.cpp" \
  "$APPLE_ROOT/bin/build-airplay-receiver.sh" "$APP/Contents/Resources/AirPlay/Sources/"
cp "$PACKAGE/README.md" "$APP/Contents/Resources/AirPlay/"
cp "$PACKAGE/.build/arm64/UxPlay-df67c212a433cf6dda3676dd40c097900d24e645/LICENSE" \
  "$APP/Contents/Resources/AirPlay/LICENSE-UxPlay"
cp "$PACKAGE/.build/arm64/libplist-2.7.0/COPYING" "$APP/Contents/Resources/AirPlay/LICENSE-libplist"
cp "$PACKAGE/.build/arm64/openssl-3.6.4/LICENSE.txt" "$APP/Contents/Resources/AirPlay/LICENSE-OpenSSL"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
  identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  [[ -n "$identity" ]] || identity=-
  signing=(--force --options runtime --sign "$identity")
  if [[ "${BLAU_CHROMIUM_CODESIGN_TIMESTAMP:-NO}" == YES && "$identity" != - ]]; then
    signing+=(--timestamp)
  fi
  codesign "${signing[@]}" "$APP/Contents/MacOS/CockpitAirPlayReceiver"
fi
# Incremental builds replace files without necessarily changing directory dates.
# A reused bundle date lets macOS retain old NSBonjourServices declarations.
# Ship fresh dates as well as doing this at local installation time.
touch "$APP" "$APP/Contents"
