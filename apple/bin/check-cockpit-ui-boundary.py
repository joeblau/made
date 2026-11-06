#!/usr/bin/env python3
"""Check Cockpit's actual Xcode source membership for SwiftUI presentation.

Widget extensions and companion targets deliberately retain SwiftUI. This check
examines Pilot's PBXSourcesBuildPhase instead of recursively rejecting those
shared directories. Regenerate the project before running the check.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
IMPORT = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*import\s+(?:SwiftUI|Charts)\b", re.MULTILINE)
HOST = re.compile(r"\bNSHosting(?:View|Controller)\s*(?:<|\(|:)")


def without_comments(source):
    # Swift block comments can nest. Keep line breaks for useful diagnostics.
    result = []
    index = 0
    depth = 0
    quoted = False
    while index < len(source):
        pair = source[index:index + 2]
        char = source[index]
        if depth:
            if pair == "/*":
                depth += 1
                index += 2
            elif pair == "*/":
                depth -= 1
                index += 2
            else:
                result.append("\n" if char == "\n" else " ")
                index += 1
        elif quoted:
            result.append(char)
            if char == "\\" and index + 1 < len(source):
                result.append(source[index + 1])
                index += 2
            else:
                quoted = char != '"'
                index += 1
        elif pair == "//":
            end = source.find("\n", index)
            if end < 0:
                break
            result.append("\n")
            index = end + 1
        elif pair == "/*":
            depth = 1
            index += 2
        else:
            result.append(char)
            quoted = char == '"'
            index += 1
    return "".join(result)


def source_paths(project, target):
    completed = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(project / "project.pbxproj")],
        check=True, text=True, capture_output=True,
    )
    data = json.loads(completed.stdout)
    objects = data["objects"]
    project_record = objects[data["rootObject"]]
    project_root = project.parent
    paths = {}

    def visit(identifier, parent):
        record = objects[identifier]
        tree = record.get("sourceTree", "<group>")
        base = project_root if tree == "SOURCE_ROOT" else parent
        path = Path(record.get("path", ""))
        resolved = path if path.is_absolute() else base / path
        paths[identifier] = resolved
        for child in record.get("children", []):
            visit(child, resolved)

    visit(project_record["mainGroup"], project_root)
    matches = [item for item in objects.values()
               if item.get("isa") == "PBXNativeTarget" and item.get("name") == target]
    if len(matches) != 1:
        raise ValueError(f"Expected one {target} native target, found {len(matches)}")
    sources = []
    for phase_id in matches[0]["buildPhases"]:
        phase = objects[phase_id]
        if phase["isa"] != "PBXSourcesBuildPhase":
            continue
        for build_file in phase["files"]:
            reference = objects[build_file].get("fileRef")
            if reference and reference in paths and paths[reference].suffix == ".swift":
                sources.append(paths[reference].resolve())
    if not sources:
        raise ValueError(f"No Swift sources resolved for {target}")
    return sorted(set(sources))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=ROOT / "apple/made.xcodeproj")
    parser.add_argument("--target", default="Pilot")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    sources = source_paths(args.project.resolve(), args.target)
    violations = []
    for path in sources:
        if not path.is_file():
            raise ValueError(f"Missing compiled source: {path}")
        text = without_comments(path.read_text())
        for pattern, reason in [(IMPORT, "SwiftUI/Swift Charts import"), (HOST, "SwiftUI hosting view/controller")]:
            for match in pattern.finditer(text):
                try:
                    display = str(path.relative_to(ROOT))
                except ValueError:
                    display = str(path)
                violations.append({"file": display, "line": text.count("\n", 0, match.start()) + 1, "reason": reason})
    report = {"target": args.target, "source_count": len(sources), "violations": violations}
    if args.json:
        print(json.dumps(report, indent=2))
    elif violations:
        for item in violations:
            print(f'{item["file"]}:{item["line"]}: {item["reason"]}', file=sys.stderr)
        print(f'{len(violations)} AppKit boundary violations in {args.target}', file=sys.stderr)
    else:
        print(f'{args.target}: {len(sources)} Swift sources, no SwiftUI presentation imports or hosts')
    return 1 if violations else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
