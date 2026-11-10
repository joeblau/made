#!/usr/bin/env bash
# Build the tmux that the Drone and Pilot terminal tests drive from SHA-256
# pinned upstream sources, instead of whatever Homebrew bottle (and bottled
# dependencies) a runner image happens to carry.
#
#   install-tmux.sh path     build once per pinned version, print the binary
#   install-tmux.sh verify   require that the tmux the apps select is this
#                            pinned build, reporting exactly "tmux $TMUX_VERSION"
#
# The libevent dependency is linked statically; ncurses comes from the macOS
# SDK. utf8proc and jemalloc are disabled so nothing is resolved from Homebrew.
set -euo pipefail

TMUX_VERSION="3.8"
TMUX_SHA256="e79c699c7e949dccd0a4a125e17b8d1261e311b16979dbc8eb34542f3966d82e"
LIBEVENT_VERSION="2.1.13-stable"
LIBEVENT_SHA256="f7e9383b8c0baa81b687e5b5eecc01beefaf1b19b64151d95ed61647fe7a315c"
EXPECTED_VERSION="tmux ${TMUX_VERSION}"

# The lookup order of DroneTmux.locate(), Workspace, and TerminalSessionTests;
# test-apple-ci-scripts.sh keeps them identical. BLAU_TMUX_CANDIDATES
# (colon-separated) substitutes the list for that test only.
CANDIDATES=(/opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux)
if [[ -n "${BLAU_TMUX_CANDIDATES:-}" ]]; then
  IFS=: read -r -a CANDIDATES <<< "$BLAU_TMUX_CANDIDATES"
fi

CACHE_ROOT="${XDG_CACHE_HOME:-${HOME}/Library/Caches}/blau/tmux/${TMUX_VERSION}-libevent-${LIBEVENT_VERSION}"
TMUX="${CACHE_ROOT}/bin/tmux"

fail() {
  printf 'install-tmux: %s\n' "$*" >&2
  exit 1
}

require_version() {
  local binary="$1" actual
  actual="$("$binary" -V 2>/dev/null)" || fail "$binary -V failed"
  [[ "$actual" == "$EXPECTED_VERSION" ]] ||
    fail "$binary reports '$actual', expected '$EXPECTED_VERSION'"
}

download() {
  local url="$1" checksum="$2" destination="$3" actual
  curl --fail --location --silent --show-error --retry 2 --connect-timeout 20 --max-time 600 \
    "$url" -o "$destination"
  actual="$(shasum -a 256 "$destination" | awk '{print $1}')"
  [[ "$actual" == "$checksum" ]] || fail "checksum mismatch for ${url##*/}: $actual"
}

build() {
  local work staging jobs
  work="$(mktemp -d "${TMPDIR:-/tmp}/blau-tmux.XXXXXX")"
  # shellcheck disable=SC2064 # Expand now; work is local to this function.
  trap "rm -rf '$work'" EXIT
  staging="$work/install"
  jobs="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 2)"

  download \
    "https://github.com/libevent/libevent/releases/download/release-${LIBEVENT_VERSION}/libevent-${LIBEVENT_VERSION}.tar.gz" \
    "$LIBEVENT_SHA256" "$work/libevent.tar.gz"
  download \
    "https://github.com/tmux/tmux/releases/download/${TMUX_VERSION}/tmux-${TMUX_VERSION}.tar.gz" \
    "$TMUX_SHA256" "$work/tmux.tar.gz"
  tar -xzf "$work/libevent.tar.gz" -C "$work"
  tar -xzf "$work/tmux.tar.gz" -C "$work"

  (
    cd "$work/libevent-${LIBEVENT_VERSION}"
    ./configure --prefix="$staging" --disable-shared --enable-static \
      --disable-openssl --disable-samples --disable-libevent-regress \
      --disable-debug-mode >&2
    make -j "$jobs" >&2
    make install >&2
  )
  (
    cd "$work/tmux-${TMUX_VERSION}"
    # PKG_CONFIG_LIBDIR confines pkg-config to the static libevent above, so a
    # Homebrew libevent, utf8proc, or ncurses on the runner is never linked.
    PKG_CONFIG_LIBDIR="$staging/lib/pkgconfig" \
      CPPFLAGS="-I$staging/include" LDFLAGS="-L$staging/lib" \
      ./configure --prefix="$staging" --disable-utf8proc --disable-jemalloc >&2
    make -j "$jobs" >&2
    make install >&2
  )
  if otool -L "$staging/bin/tmux" | grep -Eq '/(opt/homebrew|usr/local)/'; then
    fail "pinned tmux linked a Homebrew library: $(otool -L "$staging/bin/tmux")"
  fi
  require_version "$staging/bin/tmux"

  mkdir -p "$CACHE_ROOT/bin"
  install -m 0755 "$staging/bin/tmux" "$TMUX.tmp"
  mv -f "$TMUX.tmp" "$TMUX"
}

ensure_built() {
  [[ -x "$TMUX" ]] || build
  require_version "$TMUX"
}

verify_selected() {
  local candidate
  for candidate in "${CANDIDATES[@]}"; do
    if [[ -x "$candidate" ]]; then
      require_version "$candidate"
      printf '%s at %s\n' "$EXPECTED_VERSION" "$candidate"
      return 0
    fi
  done
  fail "no tmux at ${CANDIDATES[*]}; install the pinned build first"
}

case "${1:-}" in
  path)
    ensure_built
    printf '%s\n' "$TMUX"
    ;;
  verify)
    verify_selected
    ;;
  *)
    printf 'usage: %s path|verify\n' "${0##*/}" >&2
    exit 2
    ;;
esac
