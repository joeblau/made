#!/usr/bin/env bash
# Reproduce or verify the Mac mini model shown in Cockpit's 3D runner fleet.
#
#   apple/bin/fetch-runner-model.sh verify   # check the checked-in file (CI)
#   apple/bin/fetch-runner-model.sh fetch    # re-download Apple's file and pin-check it
#
# The model is Apple's unmodified public AR Quick Look file; see
# docs/runner-fleet-model.md for provenance. Changing the source requires
# updating SOURCE_URL and SOURCE_SHA256 together in one reviewed commit.
set -euo pipefail

SOURCE_URL="https://www.apple.com/105/media/us/mac-mini/2026/2140fd43-1461-420d-942c-6f254535a9a4/ar/mac-mini-silver.usdz"
SOURCE_SHA256="3d36f189975cb24e2614e1aadabc1ae6112c8a298722c2eabc67f56a4d986ace"
APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="$APPLE_ROOT/Sources/Pilot/Runners/MacMini.usdz"

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

case "${1:-verify}" in
  verify)
    [[ -f "$DESTINATION" ]] || { echo "Missing $DESTINATION" >&2; exit 1; }
    actual="$(sha256 "$DESTINATION")"
    if [[ "$actual" != "$SOURCE_SHA256" ]]; then
      echo "MacMini.usdz is $actual; expected $SOURCE_SHA256" >&2
      exit 1
    fi
    echo "MacMini.usdz matches the pinned Apple source."
    ;;
  fetch)
    download="$(mktemp)"
    trap 'rm -f "$download"' EXIT
    curl --fail --silent --show-error --location --proto '=https' --max-filesize 16000000 \
      --output "$download" "$SOURCE_URL"
    actual="$(sha256 "$download")"
    if [[ "$actual" != "$SOURCE_SHA256" ]]; then
      echo "Downloaded model is $actual; expected $SOURCE_SHA256. Apple may have replaced the file." >&2
      exit 1
    fi
    install -m 0644 "$download" "$DESTINATION"
    echo "Installed $DESTINATION"
    ;;
  *)
    echo "Usage: apple/bin/fetch-runner-model.sh [verify|fetch]" >&2
    exit 2
    ;;
esac
