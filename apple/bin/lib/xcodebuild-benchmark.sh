#!/usr/bin/env bash
set -euo pipefail

arguments=()
for argument in "$@"; do
  [[ "$argument" == -quiet ]] || arguments+=("$argument")
done

action="${arguments[0]:-unknown}"
scheme=unknown
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == -scheme && "$#" -gt 1 ]]; then
    scheme="$2"
    break
  fi
  shift
done
case "$action" in
  build|build-for-testing) phase='build' ;;
  test|test-without-building) phase='test' ;;
  *) phase='other' ;;
esac

sequence=1
while :; do
  printf -v log_name '%03d-%s-%s.log' "$sequence" "$action" "$scheme"
  [[ ! -e "$BLAU_CI_BENCHMARK_DIR/logs/$log_name" ]] && break
  ((sequence += 1))
done
log="$BLAU_CI_BENCHMARK_DIR/logs/$log_name"
started=$SECONDS
status=0
if "$BLAU_CI_BENCHMARK_XCODEBUILD" "${arguments[@]}" 2>&1 | tee "$log"; then
  status=0
else
  status=$?
fi
wall_seconds=$((SECONDS - started))

read -r swift_compile compile_c < <(awk '
  /^[ \t]*SwiftCompile[ \t]/ { swift += 1 }
  /^[ \t]*CompileC[ \t]/ { c += 1 }
  END { print swift + 0, c + 0 }
' "$log")
compile_units=$((swift_compile + compile_c))
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$phase" "$action" "$scheme" "$swift_compile" "$compile_c" \
  "$compile_units" "$wall_seconds" "$status" "logs/$log_name" \
  >> "$BLAU_CI_BENCHMARK_DIR/commands.tsv"

awk -F '\t' '
  BEGIN { OFS = "\t" }
  NR == 1 {
    print "phase", "invocations", "swift_compile", "compile_c", "compile_units", "xcodebuild_wall_seconds", "failures"
    next
  }
  {
    phase = $1
    seen[phase] = 1
    invocations[phase] += 1
    swift[phase] += $4
    c[phase] += $5
    units[phase] += $6
    wall[phase] += $7
    failures[phase] += ($8 != 0)
  }
  END {
    for (phase_index = 1; phase_index <= 3; phase_index++) {
      phase = (phase_index == 1 ? "build" : (phase_index == 2 ? "test" : "other"))
      if (phase in seen) {
        print phase, invocations[phase], swift[phase], c[phase], units[phase], wall[phase], failures[phase]
      }
    }
  }
' "$BLAU_CI_BENCHMARK_DIR/commands.tsv" > "$BLAU_CI_BENCHMARK_DIR/.totals.$$"
mv "$BLAU_CI_BENCHMARK_DIR/.totals.$$" "$BLAU_CI_BENCHMARK_DIR/totals.tsv"
printf 'CI benchmark: %s %s compile_units=%s wall_seconds=%s status=%s log=%s\n' \
  "$action" "$scheme" "$compile_units" "$wall_seconds" "$status" "logs/$log_name"
exit "$status"
