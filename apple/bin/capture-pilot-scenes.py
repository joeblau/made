#!/usr/bin/env python3
"""Render the native Cockpit scene catalog without desktop capture permissions."""

import argparse
import html
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "apple/Tests/PilotTests/Snapshots/SnapshotCatalog.swift"


def scene_names():
    # The Swift catalog owns scene IDs; no second hand-maintained list.
    import re
    source = CATALOG.read_text().split("    var title:", 1)[0]
    return [raw or name for name, raw in re.findall(r'^    case (\w+)(?: = "([^"]+)")?$', source, re.M)]


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="List scene IDs without building")
    parser.add_argument("--scenes", default="all", help="Comma-separated scene IDs (default: all)")
    parser.add_argument("--appearance", choices=["both", "light", "dark"], default="both")
    parser.add_argument("--width", type=int, default=1440, help="Logical width, 1280–2560")
    parser.add_argument("--height", type=int, default=960, help="Logical height, 800–1600")
    parser.add_argument("--scale", type=int, choices=[1, 2], default=2)
    parser.add_argument("--output", type=Path, default=ROOT / "apple/.build/snapshots/output")
    parser.add_argument("--derived-data", type=Path, default=ROOT / "apple/.build/snapshots")
    parser.add_argument("--skip-build", action="store_true", help="Reuse a successful capture build")
    args = parser.parse_args()
    names = scene_names()
    selected = names if args.scenes == "all" else args.scenes.split(",")
    if not selected or len(set(selected)) != len(selected) or any(name not in names for name in selected):
        parser.error("--scenes must contain unique scene IDs from --list")
    if not 1280 <= args.width <= 2560 or not 800 <= args.height <= 1600:
        parser.error("width must be 1280–2560 and height must be 800–1600")
    return args, selected


def run(command, log):
    print("Running " + " ".join(map(str, command[:3])) + f" … (log: {log})", flush=True)
    with log.open("w") as output:
        result = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                env={**os.environ, "DISABLE_SWIFTLINT": "1"})
    if result.returncode:
        print("\n".join(log.read_text(errors="replace").splitlines()[-70:]), file=sys.stderr)
        raise RuntimeError(f"Command failed ({result.returncode}); full log: {log}")


def configure_targets(value, environment):
    count = 0
    if isinstance(value, dict):
        if "TestBundlePath" in value and value.get("BlueprintName", "PilotTests") == "PilotTests":
            value.setdefault("EnvironmentVariables", {}).update(environment)
            value.setdefault("TestHostEnvironmentVariables", {}).update(environment)
            value["ParallelizationEnabled"] = False
            count += 1
        else:
            for child in value.values():
                count += configure_targets(child, environment)
    elif isinstance(value, list):
        for child in value:
            count += configure_targets(child, environment)
    return count


def validate_output(directory, scenes, args):
    manifest = json.loads((directory / "manifest.json").read_text())
    appearances = ["light", "dark"] if args.appearance == "both" else [args.appearance]
    expected = {(scene, appearance) for scene in scenes for appearance in appearances}
    assets = manifest["assets"]
    if len(assets) != len(expected) or {(a["scene"], a["appearance"]) for a in assets} != expected:
        raise RuntimeError("Incomplete scene manifest")
    for asset in assets:
        if Path(asset["file"]).name != asset["file"]:
            raise RuntimeError("Invalid asset filename")
        data = (directory / asset["file"]).read_bytes()
        if data[:8] != b"\x89PNG\r\n\x1a\n" or len(data) < 10_000:
            raise RuntimeError(f"Invalid or empty PNG: {asset['file']}")
        dimensions = struct.unpack(">II", data[16:24])
        if dimensions != (args.width * args.scale, args.height * args.scale):
            raise RuntimeError(f"Incorrect dimensions: {asset['file']}: {dimensions}")
        if dimensions != (asset["width"], asset["height"]):
            raise RuntimeError("Manifest dimensions do not match PNG")
    return manifest


def write_gallery(directory, manifest):
    cards = []
    for asset in manifest["assets"]:
        name, alt = html.escape(asset["file"], quote=True), html.escape(asset["alt"], quote=True)
        cards.append(f'<figure data-theme="{asset["appearance"]}"><a href="{name}"><img src="{name}" '
                     f'width="{asset["width"]}" height="{asset["height"]}" loading="lazy" alt="{alt}"></a>'
                     f'<figcaption>{html.escape(asset["scene"])} · {asset["appearance"]}</figcaption></figure>')
    (directory / "index.html").write_text('''<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Cockpit captures</title>
<style>body{font:15px system-ui;margin:32px;background:#18191c;color:#eee}h1{font-size:28px}
nav{display:flex;gap:12px;margin:24px 0}button{font:inherit;padding:8px 16px;cursor:pointer}
main{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(560px,100%),1fr));gap:24px}
figure{margin:0}img{display:block;width:100%;height:auto;border-radius:10px}figcaption{padding:12px 0;color:#aaa}
[hidden]{display:none}</style><h1>Cockpit captures</h1><p>Native panels · fictional project data · light and dark</p>
<nav aria-label="Appearance"><button onclick="filter('all')">Both</button><button onclick="filter('light')">Light</button>
<button onclick="filter('dark')">Dark</button></nav><main>''' + "\n".join(cards) + '''</main>
<script>function filter(theme){document.querySelectorAll('figure').forEach(card=>{
card.hidden=theme!=='all'&&card.dataset.theme!==theme})}</script></html>''')


def main():
    args, scenes = arguments()
    if args.list:
        print("\n".join(scene_names()))
        return
    derived = args.derived_data.resolve()
    derived.mkdir(parents=True, exist_ok=True)
    destination = "platform=macOS,arch=" + os.uname().machine
    if not args.skip_build:
        run([str(ROOT / "apple/bin/install-xcodegen.sh"), "generate", "--spec", "apple/project.yml", "--project", "apple"],
            derived / "generate.log")
        packages = Path(os.environ.get("BLAU_SOURCE_PACKAGES", str(Path(tempfile.gettempdir()) / "blau-source-packages")))
        run(["xcodebuild", "build-for-testing", "-quiet", "-project", "apple/made.xcodeproj", "-scheme", "PilotTests",
             "-destination", destination, "-derivedDataPath", str(derived), "-clonedSourcePackagesDirPath", str(packages),
             "-onlyUsePackageVersionsFromResolvedFile", "-skipPackagePluginValidation", "CODE_SIGNING_ALLOWED=NO"],
            derived / "build.log")
    candidates = list((derived / "Build/Products").glob("PilotTests_*.xctestrun"))
    if not candidates:
        raise RuntimeError("No PilotTests test run found; run without --skip-build")
    original = max(candidates, key=lambda path: path.stat().st_mtime)
    with tempfile.TemporaryDirectory(prefix="capture-", dir=derived) as temporary:
        staging = Path(temporary)
        capture = staging / "images"
        environment = {
            "MADE_SNAPSHOT_OUTPUT": str(capture), "MADE_SNAPSHOT_SCENES": args.scenes,
            "MADE_SNAPSHOT_APPEARANCE": args.appearance, "MADE_SNAPSHOT_WIDTH": str(args.width),
            "MADE_SNAPSHOT_HEIGHT": str(args.height), "MADE_SNAPSHOT_SCALE": str(args.scale),
            "TZ": "UTC", "AppleLanguages": "(en)", "AppleLocale": "en_US_POSIX",
        }
        configuration = plistlib.loads(original.read_bytes())
        if configure_targets(configuration, environment) != 1:
            raise RuntimeError("Expected exactly one PilotTests target")
        # __TESTROOT__ is relative to this file, so keep it alongside the original.
        descriptor, path = tempfile.mkstemp(prefix="capture-", suffix=".xctestrun", dir=original.parent)
        configured = Path(path)
        with os.fdopen(descriptor, "wb") as output:
            plistlib.dump(configuration, output)
        try:
            run(["xcodebuild", "test-without-building", "-quiet", "-xctestrun", str(configured), "-destination", destination,
                 "-parallel-testing-enabled", "NO", "-only-testing:PilotTests/LandingSnapshotTests",
                 "-resultBundlePath", str(staging / "Capture.xcresult")], derived / "capture.log")
            manifest = validate_output(capture, scenes, args)
            write_gallery(capture, manifest)
            output = args.output.resolve()
            output.mkdir(parents=True, exist_ok=True)
            # Publish only a complete, validated run. Unrelated files are retained.
            for source in capture.iterdir():
                shutil.copy2(source, output / source.name)
            print(f"Captured {len(manifest['assets'])} images: {output / 'index.html'}")
        finally:
            configured.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError) as error:
        sys.exit(str(error))
