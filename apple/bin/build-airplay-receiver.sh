#!/bin/bash
# Reproducible, standalone AirPlay helper. No Homebrew runtime dependencies.
set -euo pipefail
APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$APPLE_ROOT/Packages/AirPlayReceiver"
CACHE="$PACKAGE/.build"
mkdir -p "$CACHE/downloads"

download() {
  local filename="$1" checksum="$2" url="$3"
  if [[ ! -f "$CACHE/downloads/$filename" ]]; then
    curl --fail --location --silent --show-error --retry 2 --connect-timeout 20 --max-time 1200 \
      "$url" -o "$CACHE/downloads/$filename.tmp"
    mv "$CACHE/downloads/$filename.tmp" "$CACHE/downloads/$filename"
  fi
  [[ "$(shasum -a 256 "$CACHE/downloads/$filename" | awk '{print $1}')" == "$checksum" ]] || {
    printf 'AirPlay dependency checksum mismatch: %s\n' "$filename" >&2
    exit 1
  }
}

download uxplay.tar.gz 168de53ed688f87c4022d79357ce91f9608ad5c53236bff95134d19b88efeb3f \
  https://codeload.github.com/FDH2/UxPlay/tar.gz/df67c212a433cf6dda3676dd40c097900d24e645
download libplist.tar.bz2 7ac42301e896b1ebe3c654634780c82baa7cb70df8554e683ff89f7c2643eb8b \
  https://github.com/libimobiledevice/libplist/releases/download/2.7.0/libplist-2.7.0.tar.bz2
download openssl.tar.gz c6b94124bb76ac5f8aa80de121e0f922a93d3bbf1be478bd50ebc36a30dc1db1 \
  https://codeload.github.com/openssl/openssl/tar.gz/refs/tags/openssl-3.6.4

fingerprint="$(cat "$0" "$PACKAGE/main.cpp" "$PACKAGE/bounds.patch" "$PACKAGE/tests.cpp" | shasum -a 256 | awk '{print $1}')-$(xcrun --sdk macosx --show-sdk-version)"
if [[ -x "$CACHE/CockpitAirPlayReceiver" && -f "$CACHE/fingerprint" && "$(cat "$CACHE/fingerprint")" == "$fingerprint" ]]; then
  exit 0
fi
sdk="$(xcrun --sdk macosx --show-sdk-path)"
jobs="$(sysctl -n hw.logicalcpu)"
for architecture in arm64 x86_64; do
  work="$CACHE/$architecture"
  prefix="$work/install"
  mkdir -p "$work" "$prefix"
  if [[ ! -f "$prefix/lib/libcrypto.a" ]]; then
    mkdir -p "$work/openssl-3.6.4"
    tar -xzf "$CACHE/downloads/openssl.tar.gz" -C "$work/openssl-3.6.4" --strip-components=1
    (
      cd "$work/openssl-3.6.4"
      ./Configure "darwin64-$architecture-cc" no-shared no-tests no-apps no-docs \
        --prefix="$prefix" --libdir=lib -isysroot "$sdk" -mmacosx-version-min=15.0
      make -j "$jobs" build_libs
      make install_dev
    )
  fi
  if [[ ! -f "$prefix/lib/libplist-2.0.a" ]]; then
    tar -xjf "$CACHE/downloads/libplist.tar.bz2" -C "$work"
    (
      cd "$work/libplist-2.7.0"
      CC="$(xcrun -f clang)" CXX="$(xcrun -f clang++)" \
      CFLAGS="-arch $architecture -isysroot $sdk -mmacosx-version-min=15.0" \
      CXXFLAGS="-arch $architecture -isysroot $sdk -mmacosx-version-min=15.0" \
      LDFLAGS="-arch $architecture -isysroot $sdk -mmacosx-version-min=15.0" \
        ./configure --host="$architecture-apple-darwin" --prefix="$prefix" \
          --disable-shared --enable-static --without-cython --without-tests --without-tools
      make -j "$jobs"
      make install
    )
  fi
  tar -xzf "$CACHE/downloads/uxplay.tar.gz" -C "$work"
  upstream="$work/UxPlay-df67c212a433cf6dda3676dd40c097900d24e645"
  patch -d "$upstream" -p1 < "$PACKAGE/bounds.patch"
  mkdir -p "$work/objects"
  objects=()
  for source in "$upstream"/lib/*.c "$upstream"/lib/llhttp/*.c "$upstream"/lib/playfair/*.c; do
    object="$work/objects/$(basename "$source").o"
    xcrun clang -c "$source" -o "$object" -O2 -arch "$architecture" -isysroot "$sdk" \
      -mmacosx-version-min=15.0 -DNOHOLD -DPLIST_210 -DPLIST_230 \
      -I"$upstream/lib" -I"$upstream/lib/llhttp" -I"$upstream/lib/playfair" -I"$prefix/include"
    objects+=("$object")
  done
  xcrun clang++ -std=c++17 -O2 -arch "$architecture" -isysroot "$sdk" -mmacosx-version-min=15.0 \
    -I"$upstream/lib" "$PACKAGE/main.cpp" "${objects[@]}" \
    "$prefix/lib/libplist-2.0.a" "$prefix/lib/libcrypto.a" -lpthread \
    -o "$work/CockpitAirPlayReceiver"
  if [[ "$architecture" == "$(uname -m)" ]]; then
    xcrun clang++ -std=c++17 -O2 -arch "$architecture" -isysroot "$sdk" \
      -I"$upstream/lib" "$PACKAGE/tests.cpp" "$work/objects/http_request.c.o" \
      "$work/objects/api.c.o" "$work/objects/http.c.o" "$work/objects/llhttp.c.o" \
      -o "$work/parser-tests"
    "$work/parser-tests"
  fi
done
xcrun lipo -create "$CACHE/arm64/CockpitAirPlayReceiver" "$CACHE/x86_64/CockpitAirPlayReceiver" \
  -output "$CACHE/CockpitAirPlayReceiver"
printf '%s\n' "$fingerprint" > "$CACHE/fingerprint"
