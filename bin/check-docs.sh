#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

required=(
  README.md
  CLAUDE.md
  TODOS.md
  SECURITY.md
  docs/device-pairing-and-framelink.md
  docs/ghosttykit.md
  docs/operations.md
  docs/p2p-secure-messaging.md
  docs/plotter-display-policy.md
)

for path in "${required[@]}"; do
  [[ -f "$path" ]] || { echo "Missing documented path: $path" >&2; exit 1; }
done

files=(README.md CLAUDE.md TODOS.md SECURITY.md)
while IFS= read -r file; do files+=("$file"); done < <(find docs -type f -name '*.md' -print | LC_ALL=C sort)

status=0
while IFS=$'\t' read -r document target; do
  case "$target" in
    ''|'#'*|http://*|https://*|mailto:*|app://*) continue ;;
  esac
  target="${target%%#*}"
  target="${target%%\?*}"
  target="${target#<}"
  target="${target%>}"
  resolved="$(dirname "$document")/$target"
  if [[ ! -e "$resolved" ]]; then
    echo "$document: broken relative link: $target" >&2
    status=1
  fi
done < <(perl -ne 'while (/\]\(([^)]+)\)/g) { print "$ARGV\t$1\n" }' "${files[@]}")

if grep -EnR 'Three-app ecosystem|only workflow|Workspace\.swift:[0-9]|TODO[S]?:.*:[0-9]' README.md CLAUDE.md TODOS.md docs; then
  echo "Documentation contains stale architecture or source-line guidance" >&2
  status=1
fi

if ! grep -Eq 'made.*Walkie.*Kneeboard.*Trigger|four companion apps' README.md; then
  echo "README must describe all four Apple applications" >&2
  status=1
fi

if ! grep -Eq 'security/advisories/new' SECURITY.md; then
  echo "SECURITY.md must link the private reporting form" >&2
  status=1
fi

exit "$status"
