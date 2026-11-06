#!/usr/bin/env python3
"""Measure isolated Cockpit presentation fixtures in an optimized hosted test.

This runner measures panel construction/layout and repeated width changes. It
does not label these samples application launch, input latency, frame time,
energy, or live-engine performance.
"""

import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import statistics
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]


def command(args, *, cwd, log):
    with log.open("w") as stream:
        result = subprocess.run(args, cwd=cwd, env={**os.environ, "DISABLE_SWIFTLINT": "1"},
                                stdout=stream, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); inspect {log}")


def output(args, cwd=None):
    return subprocess.run(args, cwd=cwd, check=True, text=True, capture_output=True).stdout.strip()


def percentile(values, fraction):
    values = sorted(values)
    position = (len(values) - 1) * fraction
    lower = int(position)
    upper = min(lower + 1, len(values) - 1)
    return values[lower] + (values[upper] - values[lower]) * (position - lower)


def summarize(report):
    result = {}
    for scene in sorted({sample["scene"] for sample in report["samples"]}):
        samples = [sample for sample in report["samples"] if sample["scene"] == scene]
        mount = [sample["mountLayoutMilliseconds"] for sample in samples]
        resize = [value for sample in samples for value in sample["resizeLayoutMilliseconds"]]
        result[scene] = {
            "mount_count": len(mount), "mount_median_ms": statistics.median(mount),
            "mount_p95_ms": percentile(mount, 0.95),
            "mount_stdev_ms": statistics.stdev(mount) if len(mount) > 1 else 0,
            "resize_count": len(resize), "resize_median_ms": statistics.median(resize),
            "resize_p95_ms": percentile(resize, 0.95),
            "resident_bytes_last": samples[-1]["residentBytes"],
        }
    return result


def source_fingerprint(source):
    """Identify the measured dirty source tree without including source text."""
    files = subprocess.run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                           cwd=source, check=True, capture_output=True).stdout.split(b"\0")
    digest = hashlib.sha256()
    count = 0
    for encoded in sorted(set(files)):
        relative = os.fsdecode(encoded)
        if not relative.startswith(("apple/Sources/", "apple/Tests/", "apple/Packages/", "apple/project.yml",
                                    "apple/made.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/")):
            continue
        path = source / relative
        if not path.is_file() or path.suffix not in {".swift", ".h", ".m", ".mm", ".c", ".cpp", ".metal",
                                                    ".plist", ".yml", ".resolved", ".entitlements"}:
            continue
        digest.update(encoded + b"\0" + hashlib.sha256(path.read_bytes()).digest())
        count += 1
    return {"sha256": digest.hexdigest(), "file_count": count}


def validate_samples(report, implementation):
    if report.get("version") != 1 or report.get("implementation") != implementation:
        raise RuntimeError("Benchmark report has the wrong version or implementation")
    samples = report.get("samples", [])
    scenes = {sample["scene"] for sample in samples}
    if len(scenes) != 9 or len(samples) != 63:
        raise RuntimeError("Expected nine scenes with seven measured mounts each")
    for scene in scenes:
        selected = [sample for sample in samples if sample["scene"] == scene]
        if sorted(sample["iteration"] for sample in selected) != list(range(1, 8)):
            raise RuntimeError(f"Incomplete or duplicated iterations: {scene}")
    for sample in samples:
        timings = [sample["mountLayoutMilliseconds"], *sample["resizeLayoutMilliseconds"]]
        if len(timings) != 21 or any(not math.isfinite(value) or value < 0 for value in timings):
            raise RuntimeError(f"Invalid layout measurements: {sample['scene']}")
        if sample["residentBytes"] <= 0:
            raise RuntimeError(f"Missing process memory measurement: {sample['scene']}")


def product_fingerprints(configuration, test_root):
    if isinstance(configuration, dict):
        if "TestBundlePath" in configuration:
            host = configuration["TestHostPath"].replace("__TESTROOT__", str(test_root))
            bundle = configuration["TestBundlePath"].replace("__TESTHOST__", host).replace("__TESTROOT__", str(test_root))
            result = {}
            for label, directory in [("host", host), ("tests", bundle)]:
                for path in sorted((Path(directory) / "Contents/MacOS").glob("*")):
                    if path.is_file():
                        digest = hashlib.sha256()
                        with path.open("rb") as stream:
                            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                                digest.update(chunk)
                        result[label + "/" + path.name] = digest.hexdigest()
            return result
        for child in configuration.values():
            found = product_fingerprints(child, test_root)
            if found:
                return found
    elif isinstance(configuration, list):
        for child in configuration:
            found = product_fingerprints(child, test_root)
            if found:
                return found
    return {}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--derived-data", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--implementation", choices=["swiftui-baseline", "appkit"], required=True)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--baseline", type=Path, help="Compare a prior report; environments and workloads must match")
    args = parser.parse_args()
    source = args.source_root.resolve()
    derived = args.derived_data.resolve()
    report_path = args.output.resolve()
    derived.mkdir(parents=True, exist_ok=True)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    destination = "platform=macOS,arch=" + os.uname().machine
    if not args.skip_build:
        command([str(source / "apple/bin/install-xcodegen.sh"), "generate", "--spec", "apple/project.yml", "--project", "apple"],
                cwd=source, log=derived / "benchmark-generate.log")
        packages = Path(os.environ.get("BLAU_SOURCE_PACKAGES", str(Path(tempfile.gettempdir()) / "blau-source-packages")))
        command(["xcodebuild", "build-for-testing", "-quiet", "-project", "apple/made.xcodeproj", "-scheme", "PilotTests",
                 "-configuration", "Debug", "-destination", destination, "-derivedDataPath", str(derived),
                 "-clonedSourcePackagesDirPath", str(packages), "-onlyUsePackageVersionsFromResolvedFile",
                 "-skipPackagePluginValidation", "CODE_SIGNING_ALLOWED=NO",
                 "SWIFT_OPTIMIZATION_LEVEL=-O", "SWIFT_COMPILATION_MODE=wholemodule"],
                cwd=source, log=derived / "benchmark-build.log")
    candidates = list((derived / "Build/Products").glob("PilotTests_*.xctestrun"))
    if not candidates:
        raise RuntimeError("No test product; build with this runner before --skip-build")
    original = max(candidates, key=lambda path: path.stat().st_mtime)
    spec = importlib.util.spec_from_file_location("capture_pilot_scenes", source / "apple/bin/capture-pilot-scenes.py")
    capture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(capture)
    configuration = plistlib.loads(original.read_bytes())
    raw_report = derived / ("presentation-samples-" + str(os.getpid()) + ".json")
    raw_report.unlink(missing_ok=True)
    environment = {
        "MADE_PERFORMANCE_OUTPUT": str(raw_report),
        "MADE_PERFORMANCE_IMPLEMENTATION": args.implementation,
        "MADE_PERFORMANCE_REVISION": output(["git", "rev-parse", "HEAD"], cwd=source),
        "TZ": "UTC", "AppleLanguages": "(en)", "AppleLocale": "en_US_POSIX",
    }
    if capture.configure_targets(configuration, environment) != 1:
        raise RuntimeError("Expected one isolated PilotTests test host")
    descriptor, name = tempfile.mkstemp(prefix="presentation-benchmark-", suffix=".xctestrun", dir=original.parent)
    configured = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            plistlib.dump(configuration, stream)
        result_bundle = derived / ("Presentation-" + str(os.getpid()) + ".xcresult")
        command(["xcodebuild", "test-without-building", "-quiet", "-xctestrun", str(configured),
                 "-destination", destination, "-parallel-testing-enabled", "NO",
                 "-only-testing:PilotTests/CockpitPresentationPerformanceTests",
                 "-resultBundlePath", str(result_bundle)],
                cwd=source, log=derived / "benchmark-test.log")
    finally:
        configured.unlink(missing_ok=True)
    if not raw_report.is_file():
        raise RuntimeError("Benchmark did not produce its report")
    report = json.loads(raw_report.read_text())
    validate_samples(report, args.implementation)
    raw_report.unlink()
    report["metadata"] = {
        "hardware_model": output(["sysctl", "-n", "hw.model"]),
        "cpu": output(["sysctl", "-n", "machdep.cpu.brand_string"]),
        "memory_bytes": int(output(["sysctl", "-n", "hw.memsize"])),
        "macos": output(["sw_vers", "-productVersion"]),
        "macos_build": output(["sw_vers", "-buildVersion"]),
        "xcode": output(["xcodebuild", "-version"]),
        "architecture": os.uname().machine,
        "source_revision": environment["MADE_PERFORMANCE_REVISION"],
        "source_tree_dirty": bool(output(["git", "status", "--porcelain"], cwd=source)),
        "source_fingerprint": source_fingerprint(source),
        "product_sha256": product_fingerprints(configuration, original.parent),
        "configuration": "Debug; -O; wholemodule; hosted XCTest",
        "fixture_widths": [1440, 1280, 1600], "fixture_height": 960,
        "appearance": "light", "result_bundle": str(result_bundle),
    }
    report["summary"] = summarize(report)
    if args.baseline:
        baseline = json.loads(args.baseline.read_text())
        for key in ["hardware_model", "cpu", "macos", "macos_build", "xcode", "architecture", "configuration",
                    "fixture_widths", "fixture_height", "appearance"]:
            if report["metadata"][key] != baseline["metadata"][key]:
                raise RuntimeError(f"Incomparable environment field: {key}")
        if set(report["summary"]) != set(baseline["summary"]):
            raise RuntimeError("Incomparable scene sets")
        report["comparison"] = {
            scene: {metric + "_ratio": values[metric] / baseline["summary"][scene][metric]
                    for metric in ["mount_median_ms", "mount_p95_ms", "resize_median_ms", "resize_p95_ms"]
                    if baseline["summary"][scene][metric] > 0}
            for scene, values in report["summary"].items()
        }
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"report": str(report_path), "summary": report["summary"], "comparison": report.get("comparison")}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
