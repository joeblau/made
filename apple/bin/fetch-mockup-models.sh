#!/usr/bin/env bash
# Reproduce or verify the Apple AR Quick Look device models used by Cockpit's
# Mock-ups studio.
#
#   apple/bin/fetch-mockup-models.sh verify   # check the checked-in files (CI)
#   apple/bin/fetch-mockup-models.sh fetch    # re-download Apple's files and pin-check them
#
# Every model is Apple's unmodified public AR file from an apple.com product
# page; see docs/mockups.md for provenance. Change a URL and its hash together
# in one reviewed commit.
set -euo pipefail

BASE_URL="https://www.apple.com/105/media/us"
APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTINATION="$APPLE_ROOT/Sources/Pilot/Mockups/Models"

# name | path under BASE_URL | sha256
MODELS=(
  "iphone-18-pro|iphone-18-pro/2026/591df885-5ee2-4173-86e6-401021249f7c/ar/iphone-18-pro-e-sim.usdz|0f2dac354fbc6505e7917983de460f2cc68e253f96aabf52e9f0468a4803f317"
  "iphone-duo|iphone-duo/2026/9305e4b9-72d9-4c05-9381-b572adadd5e5/ar/iPhone_Duo_e-sim_Star-White_Variant.usdz|5cab2ea636da0bc0b06c8abf4809843498f7c1d680042b4f95e383b5c6a718b2"
  "iphone-air|iphone-air/2025/731189b1-a606-493f-afa4-7c766a8fd08d/ar/iphone-air-e-sim.usdz|9b7587b91e945c5699a8fbb1c79a3cd07d4d9553d11f2e0b794fddc0fe32d5b6"
  "iphone-17|iphone-17/2025/b2c72de3-1cbc-4e24-b4d3-23c7abcec4ec/ar/iphone-17-e-sim.usdz|2eb04d020c595e12884e95e13b197dab706c13797450b45ca2fa8eefbfa9404b"
  "iphone-17e-soft-pink|iphone/shared/ar/2026/44fa1631-e6c3-4596-b59b-0d58f7e8735c/iphone-17e/iphone-17e-e-sim-soft-pink.usdz|e4efca18f6fb2b3c1547d75afec4ab4170838bfe7ccc616c4cd6cdc69a48dc01"
  "iphone-17e-white|iphone/shared/ar/2026/44fa1631-e6c3-4596-b59b-0d58f7e8735c/iphone-17e/iphone-17e-e-sim-white.usdz|c509b7547ac1a1e3aaba0deed8907adf55be91a7caf53f593aeecd1a9a8b51c9"
  "iphone-17e-black|iphone/shared/ar/2026/44fa1631-e6c3-4596-b59b-0d58f7e8735c/iphone-17e/iphone-17e-e-sim-black.usdz|e5395a03c0391f62110697651063b39a58455be1217530999b7b0bdf6db218bf"
  "ipad-pro-space-black|ipad-pro/2025/adee90db-c01e-430d-b726-fe64c0063f08/ar/ipad-pro-space-black.usdz|48098daf7c49117c81a4e4e1808899b93fad081faeba6c8b65124946b83b5ac6"
  "ipad-pro-silver|ipad-pro/2025/adee90db-c01e-430d-b726-fe64c0063f08/ar/ipad-pro-silver.usdz|26a335f6653d517268a0adec6bfad08636fedf4b3a29e8b73c99943b8df14669"
  "macbook-pro-14-space-black|macbook-pro/2025/785e1bc4-d1bd-4cf4-b1b3-94b9411c9e74/ar/macbook-pro-14-in-space-black-variant.usdz|fc5855222e774b3a4bb085a6354ea598fbacf24513eebce71576a048bdaa259b"
  "macbook-pro-14-silver|macbook-pro/2024/00a46e4c-adb6-4301-aa38-917d219bff07/ar/macbook-pro-14in-silver.usdz|c53a294c0269427e46342a8b92238badc42603e9f66dd34b8e201abfaef9bda0"
)

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

verify() {
  local status=0 entry name expected file actual
  for entry in "${MODELS[@]}"; do
    IFS='|' read -r name _ expected <<<"$entry"
    file="$DESTINATION/$name.usdz"
    if [[ ! -f "$file" ]]; then
      echo "Missing $file" >&2
      status=1
      continue
    fi
    actual="$(sha256 "$file")"
    if [[ "$actual" != "$expected" ]]; then
      echo "$name.usdz is $actual; expected $expected" >&2
      status=1
    fi
  done
  # Nothing unpinned may ride along in the models directory.
  local extra
  for extra in "$DESTINATION"/*.usdz; do
    [[ -e "$extra" ]] || continue
    name="$(basename "$extra" .usdz)"
    if ! printf '%s\n' "${MODELS[@]}" | grep -q "^$name|"; then
      echo "Unpinned model $extra" >&2
      status=1
    fi
  done
  [[ $status -eq 0 ]] && echo "${#MODELS[@]} mock-up models match their pinned Apple sources."
  return $status
}

fetch() {
  mkdir -p "$DESTINATION"
  local work entry name path expected download actual
  work="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now: $work is local to this function
  trap "rm -rf '$work'" EXIT
  for entry in "${MODELS[@]}"; do
    IFS='|' read -r name path expected <<<"$entry"
    download="$work/$name.usdz"
    curl --fail --silent --show-error --location --proto '=https' --max-filesize 24000000 \
      --output "$download" "$BASE_URL/$path"
    actual="$(sha256 "$download")"
    if [[ "$actual" != "$expected" ]]; then
      echo "$name: downloaded $actual; expected $expected. Apple may have replaced the file." >&2
      exit 1
    fi
    install -m 0644 "$download" "$DESTINATION/$name.usdz"
    echo "Installed $name.usdz"
  done
}

case "${1:-verify}" in
  verify) verify ;;
  fetch) fetch ;;
  *)
    echo "Usage: apple/bin/fetch-mockup-models.sh [verify|fetch]" >&2
    exit 2
    ;;
esac
