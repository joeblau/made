#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: apple/bin/benchmark-agentic-usage.sh /absolute/new/output-directory" >&2
  exit 2
fi

# shellcheck source-path=SCRIPTDIR source=lib/xcodebuild-ci.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/xcodebuild-ci.sh"
OUTPUT_DIR="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$1")"
ITERATIONS="${MADE_USAGE_BENCHMARK_ITERATIONS:-5}"
REVISION="$(git -C "$APPLE_ROOT/.." rev-parse HEAD)"
BENCHMARK_DERIVED_DATA="${BLAU_USAGE_BENCHMARK_DERIVED_DATA:-$DERIVED_ROOT/macos-usage-benchmark}"

if [[ -e "$OUTPUT_DIR" ]]; then
  echo "Output path already exists; choose a new path to retain prior evidence: $OUTPUT_DIR" >&2
  exit 2
fi
mkdir -p "$OUTPUT_DIR"

python3 - "$OUTPUT_DIR/environment.json" "$REVISION" "$ITERATIONS" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys


def output(*args):
    return subprocess.check_output(args, text=True).strip()


path, revision, iterations = sys.argv[1:]
report = {
    "architecture": os.uname().machine,
    "configuration": "Debug with -O and whole-module optimization; hosted XCTest",
    "cpu": output("sysctl", "-n", "machdep.cpu.brand_string"),
    "hardware_model": output("sysctl", "-n", "hw.model"),
    "iterations_per_workload": int(iterations),
    "load_before": list(os.getloadavg()),
    "macos": output("sw_vers", "-productVersion"),
    "macos_build": output("sw_vers", "-buildVersion"),
    "memory_bytes": int(output("sysctl", "-n", "hw.memsize")),
    "source_revision": revision,
    "xcode": output("xcodebuild", "-version"),
}
Path(path).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
PY

if TEST_RUNNER_MADE_USAGE_BENCHMARK_OUTPUT="$OUTPUT_DIR" \
  TEST_RUNNER_MADE_USAGE_BENCHMARK_ITERATIONS="$ITERATIONS" \
  TEST_RUNNER_MADE_USAGE_BENCHMARK_REVISION="$REVISION" \
  ci_xcodebuild test "$BENCHMARK_DERIVED_DATA" \
    -scheme PilotTests \
    -destination "$MACOS_DESTINATION" \
    -parallel-testing-enabled NO \
    -only-testing:PilotTests/AgenticUsagePerformanceTests \
    -resultBundlePath "$OUTPUT_DIR/AgenticUsage.xcresult" \
    SWIFT_OPTIMIZATION_LEVEL=-O \
    SWIFT_COMPILATION_MODE=wholemodule; then
  STATUS=0
else
  STATUS=$?
fi

python3 - "$OUTPUT_DIR/environment.json" "$STATUS" <<'PY'
import json
import os
from pathlib import Path
import sys

path = Path(sys.argv[1])
report = json.loads(path.read_text())
report["load_after"] = list(os.getloadavg())
report["test_exit_status"] = int(sys.argv[2])
path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
PY

exit "$STATUS"
