#!/usr/bin/env bash
set -euo pipefail

# Package an already validated app. The release workflow signs, notarizes, and
# staples this image after creation; local builds can exercise packaging alone.
if [[ $# -ne 2 ]]; then
  echo "Usage: apple/bin/package-macos-dmg.sh Cockpit.app output.dmg" >&2
  exit 2
fi
app="$1"
output="$2"
[[ -d "$app" && "$(basename "$app")" == Cockpit.app ]] || {
  echo "Expected a built Cockpit.app." >&2; exit 1;
}
[[ ! -e "$output" ]] || { echo "Refusing to replace $output" >&2; exit 1; }
plist="$app/Contents/Info.plist"
executable="$(plutil -extract CFBundleExecutable raw "$plist")"
[[ "$executable" == Cockpit && -x "$app/Contents/MacOS/$executable" ]] || {
  echo "App executable is missing or invalid." >&2; exit 1;
}
minimum_os="$(plutil -extract LSMinimumSystemVersion raw "$plist")"
work="$(mktemp -d "${TMPDIR:-/tmp}/cockpit-dmg.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/contents" "$(dirname "$output")"
ditto "$app" "$work/contents/Cockpit.app"
ln -s /Applications "$work/contents/Applications"
cat > "$work/contents/Install Cockpit.txt" <<EOF
Welcome to Cockpit — made's development environment for macOS.

Requires macOS $minimum_os or later. Supports Apple silicon and Intel Macs.

1. Drag Cockpit.app into Applications.
2. Open Cockpit from Applications, then eject this disk image.
3. Follow Set Up Cockpit to choose permissions and check your developer tools.

The terminal, editor, and browser are included. Git, GitHub CLI, tmux,
Xcode simulators, Android tools, and Docker are optional integrations.

You can reopen setup from Cockpit > Set Up Cockpit.
Updates are available from Cockpit > Check for Updates.

Help and source: https://github.com/joeblau/made
EOF
hdiutil create -quiet -volname Cockpit -srcfolder "$work/contents" \
  -format UDZO -fs HFS+ "$output"
hdiutil verify "$output"
