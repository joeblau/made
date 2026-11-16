#!/usr/bin/env bash
set -euo pipefail

APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_ROOT="$APPLE_ROOT/Packages/ChromiumKit"
MANIFEST="$PACKAGE_ROOT/cef-artifacts.json"
PERFORMANCE_BUDGETS="$PACKAGE_ROOT/performance-budgets.json"
RUNTIME_ARCHIVE="ChromiumKitCEF.runtime.zip"
RELEASE_METADATA="ChromiumKitCEF.release.json"
CHECKSUMS="ChromiumKitCEF.checksums.txt"
NORMALIZED_TIMESTAMP="$(jq -r '.buildToolchain.normalizedTimestamp' "$MANIFEST")"

usage() {
  cat <<'EOF'
Usage:
  apple/bin/package-chromiumkit.sh manifest
  apple/bin/package-chromiumkit.sh build [empty-output-directory]

`manifest` validates the immutable CEF lock without downloading it. `build`
verifies both pinned upstream archives, produces a universal versioned CEF
framework, and writes deterministic release assets.
EOF
}

fail() {
  printf 'ChromiumKit packaging error: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 ||
    fail "missing required tool: $1"
}

validate_manifest() {
  jq -e '
    .schemaVersion == 1 and
    (.releaseID | type == "string" and length > 0) and
    (.cef.requiredXcodeMajorVersion == 27) and
    (.cef.version as $version |
      all(.sourceArchives[];
        (.distributionDirectory |
          startswith("cef_binary_\($version)_"))
      )) and
    (.sourceArchives | length == 2) and
    ([.sourceArchives[].architecture] | sort == ["arm64", "x86_64"]) and
    (all(.sourceArchives[];
      (.url | startswith("https://cef-builds.spotifycdn.com/")) and
      (.bytes | type == "number" and . > 0) and
      (.sha1 | test("^[0-9a-f]{40}$")) and
      (.sha256 | test("^[0-9a-f]{64}$")) and
      (.distributionDirectory | type == "string" and length > 0)
    )) and
    (.artifactLayout.architectures | sort == ["arm64", "x86_64"]) and
    (.artifactLayout.versionDirectory == "Versions/A") and
    (.artifactLayout.wrapperLibrary |
      endswith("/lib/libcef_dll_wrapper.a")) and
    (.artifactLayout.credits | endswith("/CREDITS.html")) and
    (.inputLayout.wrapperSources == "libcef_dll") and
    (.inputLayout.credits == "CREDITS.html") and
    (.buildToolchain.xcodeVersionPrefix == "27.") and
    (.buildToolchain.cmakeGenerator == "Xcode") and
    (.buildToolchain.cmakeConfiguration == "Release") and
    (.buildToolchain.macOSDeploymentTarget == "15.0") and
    (.buildToolchain.normalizedTimestamp == "200001010000") and
    (.helperLayout.helpers | length == 5) and
    ([.helperLayout.helpers[].role] | sort ==
      ["alerts", "base", "gpu", "plugin", "renderer"]) and
    ([.helperLayout.helpers[] |
      select(.entitlements != null) | .role] | sort ==
      ["gpu", "renderer"]) and
    (.security.chromiumSandboxRequired == true) and
    (.security.rejectedArguments == ["--no-sandbox"]) and
    (.security.forbiddenCodesignArguments == ["--deep"])
  ' "$MANIFEST" >/dev/null ||
    fail "invalid artifact lock: $MANIFEST"

  jq -e --arg releaseID "$(jq -r '.releaseID' "$MANIFEST")" '
    .schemaVersion == 1 and
    .releaseID == $releaseID and
    (.artifact.maximumCompressedBytes | type == "number" and . > 0) and
    (.artifact.maximumInstalledBytes | type == "number" and . > 0) and
    (.runtime.arm64.maximumStartupSeconds |
      type == "number" and . > 0) and
    (.runtime.arm64.maximumFirstNavigationSeconds |
      type == "number" and . > 0) and
    (.runtime.arm64.maximumHelperCleanupSeconds |
      type == "number" and . > 0) and
    (.runtime.arm64.maximumIdleCPUPercent |
      type == "number" and . > 0) and
    (.runtime.arm64.maximumIdleMessagePumpWatchdogWorkCount |
      type == "number" and . > 0 and floor == .) and
    (.runtime.arm64.maximumResidentMemoryBytes |
      type == "number" and . > 0) and
    (.runtime.x86_64.maximumStartupSeconds |
      type == "number" and . > 0) and
    (.runtime.x86_64.maximumFirstNavigationSeconds |
      type == "number" and . > 0) and
    (.runtime.x86_64.maximumHelperCleanupSeconds |
      type == "number" and . > 0) and
    (.runtime.x86_64.maximumIdleCPUPercent |
      type == "number" and . > 0) and
    (.runtime.x86_64.maximumIdleMessagePumpWatchdogWorkCount |
      type == "number" and . > 0 and floor == .) and
    (.runtime.x86_64.maximumResidentMemoryBytes |
      type == "number" and . > 0)
  ' "$PERFORMANCE_BUDGETS" >/dev/null ||
    fail "invalid performance budgets: $PERFORMANCE_BUDGETS"
}

build_wrapper() {
  local source_root="$1"
  local architecture="$2"
  local output="$3"
  local build_dir archive count reproducible_flags
  source_root="$(cd "$source_root" && pwd -P)"
  build_dir="$(dirname "$output")/build-$architecture"
  mkdir -p "$build_dir"
  build_dir="$(cd "$build_dir" && pwd -P)"
  reproducible_flags="\
-ffile-prefix-map=$source_root=/cef-source/$architecture \
-fdebug-prefix-map=$source_root=/cef-source/$architecture \
-fmacro-prefix-map=$source_root=/cef-source/$architecture \
-ffile-prefix-map=$build_dir=/cef-build/$architecture \
-fdebug-prefix-map=$build_dir=/cef-build/$architecture \
-fmacro-prefix-map=$build_dir=/cef-build/$architecture"
  cmake -S "$source_root" -B "$build_dir" \
    -G "$(jq -r '.buildToolchain.cmakeGenerator' "$MANIFEST")" \
    -DPROJECT_ARCH="$architecture" \
    -DCMAKE_OSX_ARCHITECTURES="$architecture" \
    "-DCMAKE_CXX_FLAGS=$reproducible_flags" \
    -DCMAKE_XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT= \
    -DCMAKE_XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS=NO \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$(jq -r \
      '.buildToolchain.macOSDeploymentTarget' "$MANIFEST")"
  ZERO_AR_DATE=1 cmake --build "$build_dir" \
    --config "$(jq -r '.buildToolchain.cmakeConfiguration' "$MANIFEST")" \
    --target libcef_dll_wrapper --parallel
  count="$(find "$build_dir" -type f -name libcef_dll_wrapper.a |
    wc -l | tr -d ' ')"
  [[ "$count" == 1 ]] ||
    fail "$architecture wrapper build produced $count archives"
  archive="$(find "$build_dir" -type f -name libcef_dll_wrapper.a -print)"
  [[ "$(sorted_architectures "$archive")" == "$architecture" ]] ||
    fail "$architecture wrapper archive has unexpected architectures"
  cp "$archive" "$output"
}

file_size() {
  stat -f '%z' "$1"
}

verify_download() {
  local archive="$1"
  local architecture="$2"
  local expected_bytes expected_sha1 expected_sha256
  expected_bytes="$(jq -r --arg architecture "$architecture" \
    '.sourceArchives[] | select(.architecture == $architecture) | .bytes' \
    "$MANIFEST")"
  expected_sha1="$(jq -r --arg architecture "$architecture" \
    '.sourceArchives[] | select(.architecture == $architecture) | .sha1' \
    "$MANIFEST")"
  expected_sha256="$(jq -r --arg architecture "$architecture" \
    '.sourceArchives[] | select(.architecture == $architecture) | .sha256' \
    "$MANIFEST")"

  [[ "$(file_size "$archive")" == "$expected_bytes" ]] ||
    fail "$architecture archive byte size does not match the lock"
  [[ "$(shasum -a 1 "$archive" | awk '{print $1}')" == "$expected_sha1" ]] ||
    fail "$architecture archive SHA-1 does not match the lock"
  [[ "$(shasum -a 256 "$archive" | awk '{print $1}')" == "$expected_sha256" ]] ||
    fail "$architecture archive SHA-256 does not match the lock"
}

fetch_archive() {
  local architecture="$1"
  local work="$2"
  local url checksum cache_file download
  url="$(jq -r --arg architecture "$architecture" \
    '.sourceArchives[] | select(.architecture == $architecture) | .url' \
    "$MANIFEST")"
  checksum="$(jq -r --arg architecture "$architecture" \
    '.sourceArchives[] | select(.architecture == $architecture) | .sha256' \
    "$MANIFEST")"
  cache_file="$CEF_DOWNLOAD_CACHE/$architecture-$checksum.tar.bz2"

  if [[ -f "$cache_file" ]]; then
    verify_download "$cache_file" "$architecture"
    printf '%s\n' "$cache_file"
    return
  fi

  mkdir -p "$CEF_DOWNLOAD_CACHE"
  download="$work/$architecture.download"
  curl --fail --location --proto '=https' --tlsv1.2 \
    --retry 3 --output "$download" "$url"
  verify_download "$download" "$architecture"
  if [[ -e "$cache_file" ]]; then
    fail "refusing to replace existing cache path: $cache_file"
  fi
  mv "$download" "$cache_file"
  printf '%s\n' "$cache_file"
}

extract_archive() {
  local architecture="$1"
  local archive="$2"
  local destination="$3"
  local directory
  directory="$(jq -r --arg architecture "$architecture" \
    '.sourceArchives[] | select(.architecture == $architecture) |
     .distributionDirectory' "$MANIFEST")"
  mkdir -p "$destination"
  tar -xjf "$archive" -C "$destination"
  [[ -d "$destination/$directory" ]] ||
    fail "$architecture archive is missing locked directory $directory"
  printf '%s\n' "$destination/$directory"
}

convert_framework_layout() {
  local framework="$1"
  local executable="$2"
  local entry name
  [[ ! -e "$framework/Versions" ]] ||
    fail "upstream framework unexpectedly already has Versions"
  mkdir -p "$framework/Versions/A"
  while IFS= read -r -d '' entry; do
    name="$(basename "$entry")"
    mv "$entry" "$framework/Versions/A/$name"
  done < <(
    find "$framework" -mindepth 1 -maxdepth 1 \
      ! -name Versions -print0
  )

  for name in "$executable" Libraries Resources; do
    [[ -e "$framework/Versions/A/$name" ]] ||
      fail "framework is missing $name"
    ln -s "Versions/A/$name" "$framework/$name"
  done
  ln -s A "$framework/Versions/Current"
}

sorted_architectures() {
  lipo -archs "$1" | tr ' ' '\n' | LC_ALL=C sort |
    tr '\n' ' ' | sed 's/ $//'
}

combine_library_tree() {
  local arm_tree="$1"
  local x64_tree="$2"
  local output_tree="$3"
  local arm_file relative x64_file output_file
  local arm_paths x64_paths
  arm_paths="$(mktemp "${TMPDIR:-/tmp}/chromium-arm-paths.XXXXXX")"
  x64_paths="$(mktemp "${TMPDIR:-/tmp}/chromium-x64-paths.XXXXXX")"
  find "$arm_tree" -type f -print | sed "s#^$arm_tree/##" |
    LC_ALL=C sort > "$arm_paths"
  find "$x64_tree" -type f -print | sed "s#^$x64_tree/##" |
    LC_ALL=C sort > "$x64_paths"
  cmp "$arm_paths" "$x64_paths" >/dev/null ||
    fail "CEF Libraries file sets differ between architectures"
  rm -f "$arm_paths" "$x64_paths"

  while IFS= read -r -d '' arm_file; do
    relative="${arm_file#"$arm_tree/"}"
    x64_file="$x64_tree/$relative"
    output_file="$output_tree/$relative"
    if file "$arm_file" | grep -q 'Mach-O'; then
      lipo -create "$arm_file" "$x64_file" -output "$output_file"
    else
      cmp "$arm_file" "$x64_file" >/dev/null ||
        fail "architecture-neutral library asset differs: $relative"
    fi
  done < <(find "$arm_tree" -type f -print0)
}

merge_resource_tree() {
  local arm_tree="$1"
  local x64_tree="$2"
  local arm_paths x64_paths arm_file relative
  local arm_snapshot="$arm_tree/v8_context_snapshot.arm64.bin"
  local x64_snapshot="$x64_tree/v8_context_snapshot.x86_64.bin"
  arm_paths="$(mktemp "${TMPDIR:-/tmp}/chromium-arm-resources.XXXXXX")"
  x64_paths="$(mktemp "${TMPDIR:-/tmp}/chromium-x64-resources.XXXXXX")"

  find "$arm_tree" -type f ! -name 'v8_context_snapshot.*.bin' -print |
    sed "s#^$arm_tree/##" | LC_ALL=C sort > "$arm_paths"
  find "$x64_tree" -type f ! -name 'v8_context_snapshot.*.bin' -print |
    sed "s#^$x64_tree/##" | LC_ALL=C sort > "$x64_paths"
  cmp "$arm_paths" "$x64_paths" >/dev/null ||
    fail "CEF common Resources file sets differ between architectures"
  while IFS= read -r arm_file; do
    relative="${arm_file#"$arm_tree/"}"
    cmp "$arm_file" "$x64_tree/$relative" >/dev/null ||
      fail "CEF common Resource differs: $relative"
  done < <(find "$arm_tree" -type f \
    ! -name 'v8_context_snapshot.*.bin' -print | LC_ALL=C sort)
  rm -f "$arm_paths" "$x64_paths"

  [[ -f "$arm_snapshot" && -f "$x64_snapshot" ]] ||
    fail "CEF architecture-specific V8 snapshots are missing"
  [[ "$(find "$arm_tree" -type f \
      -name 'v8_context_snapshot.*.bin' | wc -l | tr -d ' ')" == 1 ]] ||
    fail "arm64 CEF Resources contain unexpected V8 snapshots"
  [[ "$(find "$x64_tree" -type f \
      -name 'v8_context_snapshot.*.bin' | wc -l | tr -d ' ')" == 1 ]] ||
    fail "x86_64 CEF Resources contain unexpected V8 snapshots"
  cp "$x64_snapshot" "$arm_tree/"
}

validate_versioned_framework() {
  local framework="$1"
  local executable="$2"
  local expected="arm64 x86_64"
  local file_path

  [[ "$(readlink "$framework/$executable")" == \
      "Versions/A/$executable" ]] ||
    fail "invalid framework executable symlink"
  [[ "$(readlink "$framework/Libraries")" == "Versions/A/Libraries" ]] ||
    fail "invalid framework Libraries symlink"
  [[ "$(readlink "$framework/Resources")" == "Versions/A/Resources" ]] ||
    fail "invalid framework Resources symlink"
  [[ "$(readlink "$framework/Versions/Current")" == "A" ]] ||
    fail "invalid framework Current symlink"
  [[ "$(sorted_architectures \
    "$framework/Versions/A/$executable")" == "$expected" ]] ||
    fail "framework executable is not arm64+x86_64"

  while IFS= read -r -d '' file_path; do
    if file "$file_path" | grep -q 'Mach-O'; then
      [[ "$(sorted_architectures "$file_path")" == "$expected" ]] ||
        fail "non-universal framework library: $file_path"
    fi
  done < <(find "$framework/Versions/A/Libraries" -type f -print0)
}

build_release() {
  local output="$1"
  local required_xcode release_id work arm_archive x64_archive
  local arm_root x64_root framework_relative headers_relative license_relative
  local wrapper_relative credits_relative
  local executable framework_name arm_framework x64_framework universal
  local runtime_root
  local arm_wrapper x64_wrapper universal_wrapper
  local archive_path release_path checksums_path archive_sha archive_bytes
  local maximum_archive_bytes maximum_installed_bytes
  local installed_bytes installed_files_json
  local framework_key header_key wrapper_key license_key credits_key lock_key
  local xcode_version cmake_version zip_version

  required_xcode="$(jq -r '.cef.requiredXcodeMajorVersion' "$MANIFEST")"
  local selected_xcode
  selected_xcode="$(xcodebuild -version)"
  grep -Eq "^Xcode ${required_xcode}\\." <<<"$selected_xcode" ||
    fail "CEF packaging requires Xcode ${required_xcode}.x"

  mkdir -p "$output"
  [[ -z "$(find "$output" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
    fail "output directory must be empty: $output"

  work="$(mktemp -d "${TMPDIR:-/tmp}/blau-chromiumkit.XXXXXX")"
  trap 'rm -rf "${work:-}"' EXIT
  arm_archive="$(fetch_archive arm64 "$work")"
  x64_archive="$(fetch_archive x86_64 "$work")"
  arm_root="$(extract_archive arm64 "$arm_archive" "$work/arm-source")"
  x64_root="$(extract_archive x86_64 "$x64_archive" "$work/x64-source")"

  framework_relative="$(jq -r '.inputLayout.framework' "$MANIFEST")"
  framework_name="$(basename "$framework_relative")"
  headers_relative="$(jq -r '.inputLayout.headers' "$MANIFEST")"
  wrapper_relative="$(jq -r '.inputLayout.wrapperSources' "$MANIFEST")"
  license_relative="$(jq -r '.inputLayout.license' "$MANIFEST")"
  credits_relative="$(jq -r '.inputLayout.credits' "$MANIFEST")"
  executable="$(jq -r '.artifactLayout.frameworkExecutable' "$MANIFEST")"
  if [[ ! -d "$arm_root/$framework_relative" ||
        ! -d "$x64_root/$framework_relative" ]]; then
    fail "a locked distribution is missing the CEF framework"
  fi
  diff -qr "$arm_root/$headers_relative" "$x64_root/$headers_relative" \
    >/dev/null || fail "CEF headers differ between architectures"
  diff -qr "$arm_root/$wrapper_relative" "$x64_root/$wrapper_relative" \
    >/dev/null || fail "CEF wrapper sources differ between architectures"
  cmp "$arm_root/$license_relative" "$x64_root/$license_relative" \
    >/dev/null || fail "CEF licenses differ between architectures"
  cmp "$arm_root/$credits_relative" "$x64_root/$credits_relative" \
    >/dev/null || fail "Chromium credits differ between architectures"

  arm_wrapper="$work/wrapper-arm64/libcef_dll_wrapper.a"
  x64_wrapper="$work/wrapper-x86_64/libcef_dll_wrapper.a"
  mkdir -p "$(dirname "$arm_wrapper")" "$(dirname "$x64_wrapper")"
  build_wrapper "$arm_root" arm64 "$arm_wrapper"
  build_wrapper "$x64_root" x86_64 "$x64_wrapper"

  arm_framework="$work/arm.framework"
  x64_framework="$work/x64.framework"
  ditto "$arm_root/$framework_relative" "$arm_framework"
  ditto "$x64_root/$framework_relative" "$x64_framework"
  convert_framework_layout "$arm_framework" "$executable"
  convert_framework_layout "$x64_framework" "$executable"
  merge_resource_tree \
    "$arm_framework/Versions/A/Resources" \
    "$x64_framework/Versions/A/Resources"

  runtime_root="$work/runtime"
  universal="$runtime_root/CEF/Chromium Embedded Framework.framework"
  mkdir -p "$runtime_root/CEF"
  ditto "$arm_framework" "$universal"
  lipo -create \
    "$arm_framework/Versions/A/$executable" \
    "$x64_framework/Versions/A/$executable" \
    -output "$universal/Versions/A/$executable"
  combine_library_tree \
    "$arm_framework/Versions/A/Libraries" \
    "$x64_framework/Versions/A/Libraries" \
    "$universal/Versions/A/Libraries"
  ditto "$arm_root/$headers_relative" "$runtime_root/CEF/include"
  mkdir -p "$runtime_root/CEF/lib"
  universal_wrapper="$runtime_root/CEF/lib/libcef_dll_wrapper.a"
  lipo -create "$arm_wrapper" "$x64_wrapper" -output "$universal_wrapper"
  [[ "$(sorted_architectures "$universal_wrapper")" == "arm64 x86_64" ]] ||
    fail "wrapper archive is not arm64+x86_64"
  cp "$arm_root/$license_relative" "$runtime_root/CEF/LICENSE.txt"
  cp "$arm_root/$credits_relative" "$runtime_root/CEF/CREDITS.html"
  cp "$MANIFEST" "$runtime_root/CEF/cef-artifacts.json"
  validate_versioned_framework "$universal" "$executable"

  framework_key="$framework_name/Versions/A/$executable"
  header_key="include/cef_app.h"
  wrapper_key="lib/libcef_dll_wrapper.a"
  license_key="LICENSE.txt"
  credits_key="CREDITS.html"
  lock_key="cef-artifacts.json"
  installed_files_json="$(jq -n \
    --arg frameworkKey "$framework_key" \
    --arg frameworkHash "$(shasum -a 256 \
      "$runtime_root/CEF/$framework_key" | awk '{print $1}')" \
    --arg headerKey "$header_key" \
    --arg headerHash "$(shasum -a 256 \
      "$runtime_root/CEF/$header_key" | awk '{print $1}')" \
    --arg wrapperKey "$wrapper_key" \
    --arg wrapperHash "$(shasum -a 256 \
      "$runtime_root/CEF/$wrapper_key" | awk '{print $1}')" \
    --arg licenseKey "$license_key" \
    --arg licenseHash "$(shasum -a 256 \
      "$runtime_root/CEF/$license_key" | awk '{print $1}')" \
    --arg creditsKey "$credits_key" \
    --arg creditsHash "$(shasum -a 256 \
      "$runtime_root/CEF/$credits_key" | awk '{print $1}')" \
    --arg lockKey "$lock_key" \
    --arg lockHash "$(shasum -a 256 \
      "$runtime_root/CEF/$lock_key" | awk '{print $1}')" \
    '{
      ($frameworkKey): $frameworkHash,
      ($headerKey): $headerHash,
      ($wrapperKey): $wrapperHash,
      ($licenseKey): $licenseHash,
      ($creditsKey): $creditsHash,
      ($lockKey): $lockHash
    }')"
  installed_bytes="$(find "$runtime_root/CEF" -type f -exec stat -f '%z' {} + |
    awk '{ total += $1 } END { print total + 0 }')"
  xcode_version="$(xcodebuild -version | paste -sd ';' -)"
  cmake_version="$(cmake --version | sed -n '1p')"
  zip_version="$(zip -v | sed -n '1p')"

  find "$runtime_root" -exec touch -h -t "$NORMALIZED_TIMESTAMP" {} +
  archive_path="$output/$RUNTIME_ARCHIVE"
  (
    cd "$runtime_root"
    find CEF -print | LC_ALL=C sort |
      zip -X -q -y "$archive_path" -@
  )
  archive_sha="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
  archive_bytes="$(file_size "$archive_path")"
  maximum_archive_bytes="$(jq -r \
    '.artifact.maximumCompressedBytes' "$PERFORMANCE_BUDGETS")"
  maximum_installed_bytes="$(jq -r \
    '.artifact.maximumInstalledBytes' "$PERFORMANCE_BUDGETS")"
  (( archive_bytes <= maximum_archive_bytes )) ||
    fail "runtime archive exceeds its compressed-size budget"
  (( installed_bytes <= maximum_installed_bytes )) ||
    fail "runtime exceeds its installed-size budget"
  release_id="$(jq -r '.releaseID' "$MANIFEST")"
  release_path="$output/$RELEASE_METADATA"
  jq -nS \
    --arg releaseID "$release_id" \
    --arg artifact "$RUNTIME_ARCHIVE" \
    --arg artifactSHA256 "$archive_sha" \
    --argjson artifactBytes "$archive_bytes" \
    --argjson installedBytes "$installed_bytes" \
    --argjson installedFiles "$installed_files_json" \
    --arg xcodeVersion "$xcode_version" \
    --arg cmakeVersion "$cmake_version" \
    --arg zipVersion "$zip_version" \
    --slurpfile lock "$MANIFEST" \
    '{
      schemaVersion: 1,
      releaseID: $releaseID,
      artifact: $artifact,
      artifactBytes: $artifactBytes,
      artifactSHA256: $artifactSHA256,
      installedBytes: $installedBytes,
      installedFiles: $installedFiles,
      toolVersions: {
        xcode: $xcodeVersion,
        cmake: $cmakeVersion,
        zip: $zipVersion
      },
      cef: $lock[0].cef,
      sourceArchives: $lock[0].sourceArchives,
      architectures: $lock[0].artifactLayout.architectures,
      helperLayout: $lock[0].helperLayout,
      frameworkLayout: $lock[0].artifactLayout.relativeSymlinks
    }' > "$release_path"
  touch -h -t "$NORMALIZED_TIMESTAMP" "$archive_path" "$release_path"
  checksums_path="$output/$CHECKSUMS"
  (
    cd "$output"
    shasum -a 256 "$RUNTIME_ARCHIVE" "$RELEASE_METADATA" > "$CHECKSUMS"
  )
  touch -h -t "$NORMALIZED_TIMESTAMP" "$checksums_path"

  printf 'Runtime artifact: %s\nRelease metadata: %s\n' \
    "$archive_path" "$release_path"
  printf 'Compressed bytes: %s\nInstalled bytes: %s\n' \
    "$archive_bytes" "$installed_bytes"
}

for tool in jq shasum; do require_tool "$tool"; done
validate_manifest

command="${1:-}"
case "$command" in
  manifest)
    printf 'ChromiumKit artifact lock is valid: %s\n' "$MANIFEST"
    ;;
  build)
    for tool in awk cmake cmp curl diff ditto file find lipo paste readlink sed \
      stat tar touch tr xcodebuild zip; do
      require_tool "$tool"
    done
    CEF_DOWNLOAD_CACHE="${CEF_DOWNLOAD_CACHE:-$HOME/Library/Caches/app.blau/ChromiumKit/$(jq -r '.releaseID' "$MANIFEST")}"
    export CEF_DOWNLOAD_CACHE
    build_release "${2:-$APPLE_ROOT/../release-artifacts/chromiumkit-$(jq -r '.releaseID' "$MANIFEST")}"
    ;;
  *)
    usage
    exit 2
    ;;
esac
