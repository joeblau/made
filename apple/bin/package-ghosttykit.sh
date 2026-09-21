#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$APPLE_ROOT/.." && pwd)"

UPSTREAM_URL="https://github.com/ghostty-org/ghostty.git"
UPSTREAM_VERSION="1.3.1"
UPSTREAM_TAG="v${UPSTREAM_VERSION}"
UPSTREAM_TAG_OBJECT="22efb0be2bbea73e5339f5426fa3b20edabcaa11"
UPSTREAM_REVISION="332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28"
REQUIRED_ZIG="0.15.2"
REQUIRED_XCODE_MAJOR="26"
RELEASE_ID="${UPSTREAM_VERSION}-blau.2"
RELEASE_TAG="ghosttykit-${RELEASE_ID}"
BUILD_PATCH="$APPLE_ROOT/Patches/ghostty-v1.3.1-xcframework-only.patch"
LICENSE_SOURCE="$APPLE_ROOT/Packages/GhosttyKit/LICENSE.ghostty"
PACKAGING_SCRIPT="$APPLE_ROOT/bin/package-ghosttykit.sh"
ZIG_PROVENANCE_SCRIPT="$APPLE_ROOT/bin/write-ghosttykit-zig-provenance.sh"
LINK_SMOKE_SOURCE="$APPLE_ROOT/Packages/GhosttyKit/LinkSmoke/main.c"
MODULE_SMOKE_SOURCE="$APPLE_ROOT/Packages/GhosttyKit/ModuleSmoke/main.m"
RUNTIME_ARCHIVE="GhosttyKit.xcframework.zip"
SYMBOL_ARCHIVE="GhosttyKit.symbols.zip"
LICENSE_ASSET="LICENSE.ghostty"
MAX_RUNTIME_ARCHIVE_BYTES=$((40 * 1024 * 1024))
MAX_RUNTIME_EXPANDED_BYTES=$((128 * 1024 * 1024))
MAX_SYMBOL_ARCHIVE_BYTES=$((160 * 1024 * 1024))
MAX_SYMBOL_EXPANDED_BYTES=$((640 * 1024 * 1024))

usage() {
  cat <<'EOF'
Usage:
  apple/bin/package-ghosttykit.sh build [output-directory]
  apple/bin/package-ghosttykit.sh package <GhosttyKit.xcframework> [output-directory]

`build` fetches Ghostty's annotated, pinned upstream tag and creates the universal
XCFramework with Zig 0.15.2 before packaging it. `package` exists for auditing
an already built framework; release publication must use `build`.
EOF
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }
}

require_supported_xcode() {
  local version
  version="$(xcodebuild -version)"
  printf '%s\n' "$version"
  printf '%s\n' "$version" | grep -Eq "^Xcode ${REQUIRED_XCODE_MAJOR}\\." || {
    echo "GhosttyKit releases require Xcode ${REQUIRED_XCODE_MAJOR}.x" >&2
    exit 1
  }
}

verify_packaging_inputs() {
  git -C "$REPO_ROOT" diff --quiet HEAD -- \
    apple/bin/package-ghosttykit.sh \
    apple/bin/write-ghosttykit-zig-provenance.sh \
    apple/Patches/ghostty-v1.3.1-xcframework-only.patch \
    apple/Packages/GhosttyKit/LICENSE.ghostty \
    apple/Packages/GhosttyKit/LinkSmoke/main.c \
    apple/Packages/GhosttyKit/ModuleSmoke/main.m || {
      echo "GhosttyKit packaging inputs differ from the recorded Git revision" >&2
      exit 1
    }
}

archive_tree() {
  local source_parent="$1"
  local source_name="$2"
  local destination="$3"
  (
    cd "$source_parent"
    find "$source_name" -print | LC_ALL=C sort | zip -X -q -y "$destination" -@
  )
}

expected_arches() {
  case "$1" in
    macos-arm64_x86_64) echo "arm64 x86_64" ;;
    ios-arm64|ios-arm64-simulator) echo "arm64" ;;
    *) return 1 ;;
  esac
}

normalize_framework_plist() {
  local plist="$1/Info.plist"
  local libraries
  # `xcodebuild -create-xcframework` emits AvailableLibraries in completion
  # order. Replacing that array in identifier order makes otherwise identical
  # parallel builds byte-for-byte reproducible.
  libraries='[{"BinaryPath":"libghostty-fat.a","HeadersPath":"Headers","LibraryIdentifier":"ios-arm64","LibraryPath":"libghostty-fat.a","SupportedArchitectures":["arm64"],"SupportedPlatform":"ios"},{"BinaryPath":"libghostty-fat.a","HeadersPath":"Headers","LibraryIdentifier":"ios-arm64-simulator","LibraryPath":"libghostty-fat.a","SupportedArchitectures":["arm64"],"SupportedPlatform":"ios","SupportedPlatformVariant":"simulator"},{"BinaryPath":"libghostty.a","HeadersPath":"Headers","LibraryIdentifier":"macos-arm64_x86_64","LibraryPath":"libghostty.a","SupportedArchitectures":["arm64","x86_64"],"SupportedPlatform":"macos"}]'
  plutil -replace AvailableLibraries -json "$libraries" "$plist"
}

normalize_module_maps() {
  local framework="$1"
  local headers
  for headers in "$framework"/*/Headers; do
    # Ghostty's embedding module exposes ghostty.h. The adjacent ghostty/vt
    # headers form a separate C API and must not be inferred as missing
    # umbrella members by Clang.
    printf '%s\n' \
      'module GhosttyKit {' \
      '  header "ghostty.h"' \
      '  export *' \
      '}' > "$headers/module.modulemap"
  done
}

validate_framework() {
  local framework="$1"
  local plist="$framework/Info.plist"
  local total_bytes
  local reference_headers="$framework/macos-arm64_x86_64/Headers"

  plutil -lint "$plist" >/dev/null
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$plist")" == "XFWK" ]]
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :AvailableLibraries' "$plist" | grep -Ec 'LibraryIdentifier =')" == "3" ]]
  [[ -f "$reference_headers/ghostty.h" ]]
  [[ -f "$reference_headers/module.modulemap" ]]
  grep -Fx 'module GhosttyKit {' "$reference_headers/module.modulemap" >/dev/null
  grep -Fx '  header "ghostty.h"' "$reference_headers/module.modulemap" >/dev/null

  for identifier in macos-arm64_x86_64 ios-arm64 ios-arm64-simulator; do
    local directory="$framework/$identifier"
    local index=""
    local library
    local library_name
    local platform
    local variant
    local actual
    local expected

    for candidate in 0 1 2; do
      if [[ "$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$candidate:LibraryIdentifier" "$plist")" == "$identifier" ]]; then
        index="$candidate"
        break
      fi
    done
    [[ -n "$index" ]] || { echo "Info.plist is missing $identifier" >&2; return 1; }

    case "$identifier" in
      macos-arm64_x86_64)
        library_name="libghostty.a"
        platform="macos"
        variant=""
        ;;
      ios-arm64)
        library_name="libghostty-fat.a"
        platform="ios"
        variant=""
        ;;
      ios-arm64-simulator)
        library_name="libghostty-fat.a"
        platform="ios"
        variant="simulator"
        ;;
    esac
    [[ "$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$index:LibraryPath" "$plist")" == "$library_name" ]]
    [[ "$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$index:BinaryPath" "$plist")" == "$library_name" ]]
    [[ "$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$index:HeadersPath" "$plist")" == "Headers" ]]
    [[ "$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$index:SupportedPlatform" "$plist")" == "$platform" ]]
    if [[ -n "$variant" ]]; then
      [[ "$(/usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$index:SupportedPlatformVariant" "$plist")" == "$variant" ]]
    elif /usr/libexec/PlistBuddy -c "Print :AvailableLibraries:$index:SupportedPlatformVariant" "$plist" >/dev/null 2>&1; then
      echo "Info.plist has an unexpected platform variant for $identifier" >&2
      return 1
    fi

    library="$(find "$directory" -maxdepth 1 -type f -name '*.a' -print -quit)"
    [[ -n "$library" ]] || { echo "Missing static library for $identifier" >&2; return 1; }
    [[ "$(basename "$library")" == "$library_name" ]]
    expected="$(expected_arches "$identifier")"
    actual="$(lipo -archs "$library" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
    expected="$(printf '%s\n' $expected | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
    [[ "$actual" == "$expected" ]] || {
      echo "$identifier architectures are '$actual'; expected '$expected'" >&2
      return 1
    }
    if [[ "$identifier" == "macos-arm64_x86_64" ]]; then
      for architecture in arm64 x86_64; do
        for symbol in _ghostty_config_new _ghostty_app_new _ghostty_surface_new; do
          nm -arch "$architecture" -gU "$library" | grep -F " $symbol" >/dev/null
        done
      done
    else
      for symbol in _ghostty_config_new _ghostty_app_new _ghostty_surface_new; do
        nm -gU "$library" | grep -F " $symbol" >/dev/null
      done
    fi
    diff -qr "$reference_headers" "$directory/Headers" >/dev/null
  done

  total_bytes="$(du -sk "$framework" | awk '{print $1 * 1024}')"
  (( total_bytes <= MAX_RUNTIME_EXPANDED_BYTES )) || {
    echo "Expanded XCFramework is $total_bytes bytes; budget is $MAX_RUNTIME_EXPANDED_BYTES" >&2
    return 1
  }
}

link_smoke_tests() {
  local framework="$1"
  local output="$2"
  local mac_slice="$framework/macos-arm64_x86_64"
  local ios_slice="$framework/ios-arm64"
  local simulator_slice="$framework/ios-arm64-simulator"
  local mac_library="$mac_slice/libghostty.a"
  local ios_library="$ios_slice/libghostty-fat.a"
  local simulator_library="$simulator_slice/libghostty-fat.a"

  # Compile the actual Clang module for every SDK/slice. This catches malformed
  # module maps and incomplete umbrella-header diagnostics, not just direct
  # textual inclusion of ghostty.h.
  xcrun --sdk macosx clang -arch arm64 -fmodules -fsyntax-only \
    -fmodule-map-file="$mac_slice/Headers/module.modulemap" \
    -I "$mac_slice/Headers" "$MODULE_SMOKE_SOURCE"
  xcrun --sdk macosx clang -arch x86_64 -fmodules -fsyntax-only \
    -fmodule-map-file="$mac_slice/Headers/module.modulemap" \
    -I "$mac_slice/Headers" "$MODULE_SMOKE_SOURCE"
  xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=18.0 -fmodules -fsyntax-only \
    -fmodule-map-file="$ios_slice/Headers/module.modulemap" \
    -I "$ios_slice/Headers" "$MODULE_SMOKE_SOURCE"
  xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=18.0 \
    -fmodules -fsyntax-only \
    -fmodule-map-file="$simulator_slice/Headers/module.modulemap" \
    -I "$simulator_slice/Headers" "$MODULE_SMOKE_SOURCE"

  xcrun --sdk macosx clang -arch arm64 -DGHOSTTY_STATIC \
    -I "$mac_slice/Headers" \
    "$LINK_SMOKE_SOURCE" \
    "$mac_library" \
    -o "$output-macos-arm64" \
    -lc++ \
    -framework Metal -framework MetalKit -framework QuartzCore \
    -framework CoreText -framework IOKit -framework IOSurface \
    -framework CoreGraphics -framework Foundation -framework Carbon \
    -framework CoreFoundation -framework AppKit -framework CoreServices \
    -framework AVFoundation -framework CoreMedia -framework CoreMediaIO
  xcrun --sdk macosx clang -arch x86_64 -DGHOSTTY_STATIC \
    -I "$mac_slice/Headers" \
    "$LINK_SMOKE_SOURCE" \
    "$mac_library" \
    -o "$output-macos-x86_64" \
    -lc++ \
    -framework Metal -framework MetalKit -framework QuartzCore \
    -framework CoreText -framework IOKit -framework IOSurface \
    -framework CoreGraphics -framework Foundation -framework Carbon \
    -framework CoreFoundation -framework AppKit -framework CoreServices \
    -framework AVFoundation -framework CoreMedia -framework CoreMediaIO
  xcrun --sdk iphoneos clang -arch arm64 -mios-version-min=18.0 -DGHOSTTY_STATIC \
    -I "$ios_slice/Headers" \
    "$LINK_SMOKE_SOURCE" \
    "$ios_library" \
    -o "$output-ios-arm64" \
    -lc++ \
    -framework Metal -framework MetalKit -framework QuartzCore \
    -framework CoreText -framework UIKit -framework IOSurface \
    -framework CoreGraphics -framework Foundation -framework CoreFoundation \
    -framework AVFoundation -framework CoreMedia
  xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=18.0 \
    -DGHOSTTY_STATIC -I "$simulator_slice/Headers" \
    "$LINK_SMOKE_SOURCE" \
    "$simulator_library" \
    -o "$output-ios-simulator-arm64" \
    -lc++ \
    -framework Metal -framework MetalKit -framework QuartzCore \
    -framework CoreText -framework UIKit -framework IOSurface \
    -framework CoreGraphics -framework Foundation -framework CoreFoundation \
    -framework AVFoundation -framework CoreMedia

  case "$(uname -m)" in
    arm64) "$output-macos-arm64" ;;
    x86_64) "$output-macos-x86_64" ;;
    *) echo "Unsupported macOS host architecture: $(uname -m)" >&2; return 1 ;;
  esac
}

package_framework() {
  local source_framework="$1"
  local output_directory="$2"
  local work="$3"
  mkdir -p "$output_directory"
  output_directory="$(cd "$output_directory" && pwd)"
  local runtime_root="$work/runtime"
  local symbols_root="$work/symbols/GhosttyKit.symbols"
  local staged_framework="$runtime_root/GhosttyKit.xcframework"
  local runtime_path="$output_directory/$RUNTIME_ARCHIVE"
  local symbols_path="$output_directory/$SYMBOL_ARCHIVE"
  local license_path="$output_directory/$LICENSE_ASSET"
  local metadata_path="$output_directory/GhosttyKit.release.json"
  local checksum_path="$output_directory/GhosttyKit.checksums.txt"

  [[ -d "$source_framework" ]] || { echo "XCFramework not found: $source_framework" >&2; exit 1; }
  mkdir -p "$runtime_root" "$symbols_root"
  cp -R "$source_framework" "$staged_framework"

  # Preserve every unstripped library and any upstream dSYM/symbol-map output
  # in a separate maintainer artifact before modifying the runtime framework.
  while IFS= read -r -d '' source; do
    local relative="${source#"$source_framework"/}"
    mkdir -p "$symbols_root/$(dirname "$relative")"
    cp -R "$source" "$symbols_root/$relative"
  done < <(find "$source_framework" \( -type f -name '*.a' -o -type d -name '*.dSYM' -o -type f -name '*.bcsymbolmap' \) -print0)

  while IFS= read -r -d '' library; do
    # Apple archive tools otherwise stamp their output with the current time,
    # changing SwiftPM's checksum even when every object is identical.
    ZERO_AR_DATE=1 xcrun strip -S "$library"
    ZERO_AR_DATE=1 xcrun ranlib "$library"
  done < <(find "$staged_framework" -type f -name '*.a' -print0)
  find "$staged_framework" -type d -name '*.dSYM' -prune -exec rm -rf {} +
  find "$staged_framework" -type f -name '*.bcsymbolmap' -delete

  normalize_module_maps "$staged_framework"
  validate_framework "$staged_framework"
  normalize_framework_plist "$staged_framework"
  validate_framework "$staged_framework"
  link_smoke_tests "$staged_framework" "$work/ghostty-link-smoke"

  # Normalize mtimes and traversal order. Zip's -X removes host-specific extra
  # attributes, producing a stable SwiftPM checksum for identical inputs.
  find "$runtime_root" "$work/symbols" -exec touch -t 202601010000 {} +
  rm -f "$runtime_path" "$symbols_path"
  archive_tree "$runtime_root" "GhosttyKit.xcframework" "$runtime_path"
  archive_tree "$work/symbols" "GhosttyKit.symbols" "$symbols_path"
  cp "$LICENSE_SOURCE" "$license_path"
  touch -t 202601010000 "$license_path"

  local archive_bytes
  local archive_sha
  local symbols_sha
  local license_sha
  local swift_checksum
  local runtime_expanded_bytes
  local symbols_bytes
  local symbols_expanded_bytes
  local headers_sha
  local build_patch_sha
  local packaging_script_sha
  local packaging_revision
  local zig_provenance_script_sha
  local link_smoke_sha
  local module_smoke_sha
  local zig_toolchain_sha
  local zig_toolchain_json
  local xcode_version
  archive_bytes="$(stat -f '%z' "$runtime_path")"
  (( archive_bytes <= MAX_RUNTIME_ARCHIVE_BYTES )) || {
    echo "Runtime archive is $archive_bytes bytes; budget is $MAX_RUNTIME_ARCHIVE_BYTES" >&2
    exit 1
  }
  archive_sha="$(shasum -a 256 "$runtime_path" | awk '{print $1}')"
  runtime_expanded_bytes="$(du -sk "$staged_framework" | awk '{print $1 * 1024}')"
  symbols_bytes="$(stat -f '%z' "$symbols_path")"
  symbols_expanded_bytes="$(du -sk "$symbols_root" | awk '{print $1 * 1024}')"
  (( symbols_bytes <= MAX_SYMBOL_ARCHIVE_BYTES )) || {
    echo "Symbols archive is $symbols_bytes bytes; budget is $MAX_SYMBOL_ARCHIVE_BYTES" >&2
    exit 1
  }
  (( symbols_expanded_bytes <= MAX_SYMBOL_EXPANDED_BYTES )) || {
    echo "Expanded symbols are $symbols_expanded_bytes bytes; budget is $MAX_SYMBOL_EXPANDED_BYTES" >&2
    exit 1
  }
  symbols_sha="$(shasum -a 256 "$symbols_path" | awk '{print $1}')"
  license_sha="$(shasum -a 256 "$license_path" | awk '{print $1}')"
  swift_checksum="$(swift package compute-checksum "$runtime_path")"
  [[ "$archive_sha" == "$swift_checksum" ]]
  headers_sha="$(
    cd "$staged_framework/macos-arm64_x86_64/Headers"
    find . -type f -print0 \
      | LC_ALL=C sort -z \
      | xargs -0 shasum -a 256 \
      | shasum -a 256 \
      | awk '{print $1}'
  )"
  build_patch_sha="$(shasum -a 256 "$BUILD_PATCH" | awk '{print $1}')"
  packaging_script_sha="$(shasum -a 256 "$PACKAGING_SCRIPT" | awk '{print $1}')"
  zig_provenance_script_sha="$(shasum -a 256 "$ZIG_PROVENANCE_SCRIPT" | awk '{print $1}')"
  link_smoke_sha="$(shasum -a 256 "$LINK_SMOKE_SOURCE" | awk '{print $1}')"
  module_smoke_sha="$(shasum -a 256 "$MODULE_SMOKE_SOURCE" | awk '{print $1}')"
  [[ -f "${GHOSTTYKIT_ZIG_PROVENANCE_FILE:-}" ]] || {
    echo "GHOSTTYKIT_ZIG_PROVENANCE_FILE must name the pinned Zig provenance JSON" >&2
    exit 1
  }
  jq -e '
    .schemaVersion == 1 and
    .version == "0.15.2_1" and
    .formulaRevision == "1" and
    .formulaGitRevision == "66277812877bd6b470da86a59208ef0be903ca0c" and
    .formulaSHA256 == "91e0a69da295d32f65938042255de5199ebc83602d5b87a517acad1bb3ec9829" and
    .sourceSHA256 == "d9b30c7aa983fcff5eed2084d54ae83eaafe7ff3a84d8fb754d854165a6e521c"
  ' "$GHOSTTYKIT_ZIG_PROVENANCE_FILE" >/dev/null
  [[ "$(jq -r .executableSHA256 "$GHOSTTYKIT_ZIG_PROVENANCE_FILE")" == \
      "$(shasum -a 256 "$(command -v zig)" | awk '{print $1}')" ]]
  zig_toolchain_sha="$(shasum -a 256 "$GHOSTTYKIT_ZIG_PROVENANCE_FILE" | awk '{print $1}')"
  zig_toolchain_json="$(jq -cS . "$GHOSTTYKIT_ZIG_PROVENANCE_FILE")"
  packaging_revision="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  xcode_version="$(xcodebuild -version | paste -sd ' ' -)"

  printf '%s\n' \
    '{' \
    '  "schemaVersion": 2,' \
    "  \"upstream\": \"$UPSTREAM_URL\"," \
    "  \"upstreamVersion\": \"$UPSTREAM_VERSION\"," \
    "  \"upstreamRevision\": \"$UPSTREAM_REVISION\"," \
    "  \"requiredZigVersion\": \"$REQUIRED_ZIG\"," \
    "  \"requiredXcodeMajorVersion\": \"$REQUIRED_XCODE_MAJOR\"," \
    "  \"xcodeVersion\": \"$xcode_version\"," \
    '  "packagingRepository": "https://github.com/joeblau/made",' \
    "  \"packagingRevision\": \"$packaging_revision\"," \
    "  \"packagingScriptSHA256\": \"$packaging_script_sha\"," \
    "  \"zigProvenanceScriptSHA256\": \"$zig_provenance_script_sha\"," \
    "  \"linkSmokeSourceSHA256\": \"$link_smoke_sha\"," \
    "  \"moduleSmokeSourceSHA256\": \"$module_smoke_sha\"," \
    "  \"zigToolchainSHA256\": \"$zig_toolchain_sha\"," \
    "  \"zigToolchain\": $zig_toolchain_json," \
    "  \"buildOnlyPatchSHA256\": \"$build_patch_sha\"," \
    "  \"releaseTag\": \"$RELEASE_TAG\"," \
    "  \"artifact\": \"$RUNTIME_ARCHIVE\"," \
    "  \"artifactBytes\": $archive_bytes," \
    "  \"artifactExpandedBytes\": $runtime_expanded_bytes," \
    "  \"artifactSHA256\": \"$archive_sha\"," \
    "  \"swiftPMChecksum\": \"$swift_checksum\"," \
    "  \"symbolsArtifact\": \"$SYMBOL_ARCHIVE\"," \
    "  \"symbolsArtifactBytes\": $symbols_bytes," \
    "  \"symbolsExpandedBytes\": $symbols_expanded_bytes," \
    "  \"symbolsSHA256\": \"$symbols_sha\"," \
    "  \"licenseArtifact\": \"$LICENSE_ASSET\"," \
    "  \"licenseSHA256\": \"$license_sha\"," \
    "  \"headersTreeSHA256\": \"$headers_sha\"," \
    '  "sizeBudgets": {' \
    "    \"runtimeArchiveBytes\": $MAX_RUNTIME_ARCHIVE_BYTES," \
    "    \"runtimeExpandedBytes\": $MAX_RUNTIME_EXPANDED_BYTES," \
    "    \"symbolsArchiveBytes\": $MAX_SYMBOL_ARCHIVE_BYTES," \
    "    \"symbolsExpandedBytes\": $MAX_SYMBOL_EXPANDED_BYTES" \
    '  },' \
    '  "architectures": {' \
    '    "macOS": ["arm64", "x86_64"],' \
    '    "iOS": ["arm64"],' \
    '    "iOSSimulator": ["arm64"]' \
    '  },' \
    '  "validation": {' \
    '    "strip": "Apple strip -S completed for every static library",' \
    '    "requiredSymbols": ["_ghostty_config_new", "_ghostty_app_new", "_ghostty_surface_new"],' \
    '    "linkedConsumers": ["macOS arm64", "macOS x86_64", "iOS arm64", "iOS Simulator arm64"],' \
    '    "hostMacOSConsumer": "compiled, linked, and exited successfully",' \
    '    "headersAndModuleMap": "identical and module-imported across all slices"' \
    '  }' \
    '}' > "$metadata_path"

  (
    cd "$output_directory"
    shasum -a 256 \
      "$(basename "$runtime_path")" \
      "$(basename "$symbols_path")" \
      "$(basename "$license_path")" \
      "$(basename "$metadata_path")" \
      > "$(basename "$checksum_path")"
  )
  echo "Runtime artifact: $runtime_path"
  echo "Symbols artifact: $symbols_path"
  echo "License artifact: $license_path"
  echo "SwiftPM checksum: $swift_checksum"
  echo "Release metadata: $metadata_path"
}

command="${1:-}"
case "$command" in
  build)
    output_directory="${2:-$REPO_ROOT/release-artifacts/$RELEASE_TAG}"
    for tool in git jq zig xcodebuild xcrun zip shasum swift plutil lipo nm; do require_tool "$tool"; done
    require_supported_xcode
    verify_packaging_inputs
    [[ "$(zig version)" == "$REQUIRED_ZIG" ]] || {
      echo "Ghostty $UPSTREAM_TAG requires Zig $REQUIRED_ZIG (found $(zig version))" >&2
      exit 1
    }
    # Some upstream C/C++ objects retain their compilation directory even
    # after debug symbols are stripped. Keep that directory stable so two
    # clean builds of the pinned revision produce the same archive bytes.
    work="/tmp/blau-ghosttykit-$UPSTREAM_REVISION"
    lock="$work.lock"
    mkdir "$lock" 2>/dev/null || {
      echo "Another GhosttyKit build is using $work" >&2
      exit 1
    }
    trap 'rm -rf "${work:-}" "${lock:-}"' EXIT
    rm -rf "$work"
    mkdir -p "$work"
    source_root="$work/ghostty"
    git init -q "$source_root"
    git -C "$source_root" remote add origin "$UPSTREAM_URL"
    git -C "$source_root" fetch -q --depth=1 origin "refs/tags/$UPSTREAM_TAG:refs/tags/$UPSTREAM_TAG"
    [[ "$(git -C "$source_root" rev-parse "$UPSTREAM_TAG^{tag}")" == "$UPSTREAM_TAG_OBJECT" ]]
    [[ "$(git -C "$source_root" rev-parse "$UPSTREAM_TAG^{commit}")" == "$UPSTREAM_REVISION" ]]
    git -C "$source_root" checkout -q --detach "$UPSTREAM_TAG^{commit}"
    git -C "$source_root" apply --check "$BUILD_PATCH"
    git -C "$source_root" apply "$BUILD_PATCH"
    export SOURCE_DATE_EPOCH="$(git -C "$source_root" show -s --format=%ct HEAD)"
    # Compiler output also records Zig cache paths. Put both caches beneath the
    # fixed, freshly-created work root so paths and cache state are identical
    # for every release build on every machine.
    export ZIG_GLOBAL_CACHE_DIR="$work/zig-global-cache"
    export ZIG_LOCAL_CACHE_DIR="$work/zig-local-cache"
    (
      cd "$source_root"
      zig build \
        -Doptimize=ReleaseFast \
        -Demit-xcframework=true \
        -Demit-macos-app=false \
        -Dxcframework-target=universal
    )
    package_framework "$source_root/macos/GhosttyKit.xcframework" "$output_directory" "$work/package"
    ;;
  package)
    [[ $# -ge 2 ]] || { usage; exit 2; }
    for tool in git jq zig xcodebuild xcrun zip shasum swift plutil lipo nm; do require_tool "$tool"; done
    require_supported_xcode
    verify_packaging_inputs
    output_directory="${3:-$REPO_ROOT/release-artifacts/$RELEASE_TAG}"
    work="$(mktemp -d -t blau-ghosttykit-package.XXXXXX)"
    trap 'rm -rf "${work:-}"' EXIT
    package_framework "$(cd "$(dirname "$2")" && pwd)/$(basename "$2")" "$output_directory" "$work"
    ;;
  *) usage; exit 2 ;;
esac
