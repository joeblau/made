#!/usr/bin/env bash
set -euo pipefail

VERSION="2.45.4"
ARCHIVE_SHA256="090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef"
CACHE_ROOT="${XDG_CACHE_HOME:-${HOME}/Library/Caches}/blau/xcodegen/${VERSION}"
XCODEGEN="${CACHE_ROOT}/xcodegen/bin/xcodegen"
APPLE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -x "$XCODEGEN" ]]; then
  mkdir -p "$CACHE_ROOT"
  archive="$(mktemp -t blau-xcodegen.XXXXXX.zip)"
  trap 'rm -f "${archive:-}"' EXIT
  curl -fsSL "https://github.com/yonaskolb/XcodeGen/releases/download/${VERSION}/xcodegen.zip" -o "$archive"
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  [[ "$actual" == "$ARCHIVE_SHA256" ]] || {
    echo "XcodeGen checksum mismatch" >&2
    exit 1
  }
  unzip -qo "$archive" -d "$CACHE_ROOT"
fi

# `check-committed` regenerates apple/made.xcodeproj from apple/project.yml and
# fails unless the result is exactly what is committed. `git diff` ignores
# untracked files, so it would miss a newly generated scheme or workspace file
# that was never committed; `git status` reports those as well as modified and
# deleted files, while still honouring .gitignore for per-user Xcode state.
if [[ "${1:-}" == check-committed ]]; then
  [[ $# -eq 1 ]] || {
    echo "usage: ${0##*/} check-committed" >&2
    exit 2
  }
  cd "$APPLE_ROOT/.."
  "$XCODEGEN" generate --spec apple/project.yml --project apple
  drift="$(git status --porcelain --untracked-files=all -- apple/made.xcodeproj)"
  if [[ -n "$drift" ]]; then
    {
      echo "apple/made.xcodeproj does not match apple/project.yml."
      echo "Regenerate it with apple/bin/install-xcodegen.sh and commit every change:"
      printf '%s\n' "$drift"
      git --no-pager diff -- apple/made.xcodeproj
    } >&2
    exit 1
  fi
  exit 0
fi

exec "$XCODEGEN" "$@"
