#!/usr/bin/env python3
"""Bake brand logo paths into SF Symbols Template v.7.0 scaffolds.

Reuses the repo's known-good android-robot.symbolset scaffold (Notes + Guides),
fitting each brand's artwork into the cap-height box at the Ultralight/Regular/
Black 'Small' anchors with a uniform scale + translate baked into coordinates
(no runtime transforms, matching how the robot was exported).
"""
import math
import os
import re

# Resolve everything relative to this script so regeneration is path-independent:
# apple/bin/make-brand-symbols.py  ->  repo root is two directories up.
BIN = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(BIN))
SOURCES = os.path.join(BIN, "brand-symbol-sources")
ROBOT = os.path.join(
    REPO, "apple/Sources/Pilot/Assets.xcassets/AndroidRobot.symbolset/android-robot.svg"
)
ASSETS = os.path.join(REPO, "apple/Sources/Pilot/Assets.xcassets")

# Anchor x-centers and cap box from the robot scaffold's guides.
ANCHORS = {"Ultralight-S": 559.711, "Regular-S": 1449.84, "Black-S": 2933.4}
CAPLINE = 625.541
BASELINE = 696.0
CAP_MID = (CAPLINE + BASELINE) / 2.0
FIT_BOX = 70.0  # larger glyph dimension fits this many points

# brand -> (source svg filename, symbolset name, descriptive name, fill_rule, provenance)
SIMPLE = ("Simple Icons (https://simpleicons.org), icon data under CC0 1.0. "
          "The logo is a trademark of its owner, used here only to identify the "
          "provider's usage card (nominative use).")
LOBE = ("LobeHub Icons (https://github.com/lobehub/lobe-icons), MIT. The logo "
        "is a trademark of its owner, used here only to identify the provider's "
        "usage card (nominative use).")
BRANDS = [
    ("anthropic.svg", "BrandAnthropic", "anthropic", None, "Anthropic logomark. " + SIMPLE),
    ("openai.svg", "BrandOpenAI", "openai", None, "OpenAI logomark. " + SIMPLE),
    ("moonshotai.svg", "BrandMoonshot", "moonshot", None, "Moonshot AI logomark. " + SIMPLE),
    ("xai.svg", "BrandGrok", "grok", "evenodd", "Grok / xAI logomark. " + LOBE),
    ("cursor.svg", "BrandCursor", "cursor", None, "Cursor logomark. " + SIMPLE),
]

# ---- minimal SVG path parsing (absolute+relative, with arcs) ----
NUM = re.compile(r"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?")
CMD = re.compile(r"[MmLlHhVvCcSsQqTtAaZz]")


def tokenize(d):
    out, i = [], 0
    while i < len(d):
        m = CMD.match(d, i)
        if not m:
            i += 1
            continue
        cmd = m.group()
        i = m.end()
        nums = []
        while True:
            nm = NUM.match(d, i)
            # skip separators
            while i < len(d) and d[i] in " ,\t\n\r":
                i += 1
                nm = NUM.match(d, i)
            if not nm or (nm.group() in ("", ".", "+", "-")):
                break
            nums.append(float(nm.group()))
            i = nm.end()
        out.append((cmd, nums))
    return out


def cubic(p0, p1, p2, p3, n=16):
    for k in range(n + 1):
        t = k / n
        mt = 1 - t
        x = mt**3 * p0[0] + 3 * mt**2 * t * p1[0] + 3 * mt * t**2 * p2[0] + t**3 * p3[0]
        y = mt**3 * p0[1] + 3 * mt**2 * t * p1[1] + 3 * mt * t**2 * p2[1] + t**3 * p3[1]
        yield (x, y)


def quad(p0, p1, p2, n=16):
    for k in range(n + 1):
        t = k / n
        mt = 1 - t
        x = mt**2 * p0[0] + 2 * mt * t * p1[0] + t**2 * p2[0]
        y = mt**2 * p0[1] + 2 * mt * t * p1[1] + t**2 * p2[1]
        yield (x, y)


def arc_points(p0, rx, ry, phi_deg, large, sweep, p1, n=24):
    # endpoint -> center parameterization (SVG spec), sampled.
    x0, y0 = p0
    x1, y1 = p1
    if rx == 0 or ry == 0 or (x0 == x1 and y0 == y1):
        yield p1
        return
    phi = math.radians(phi_deg)
    cosp, sinp = math.cos(phi), math.sin(phi)
    dx, dy = (x0 - x1) / 2, (y0 - y1) / 2
    x1p = cosp * dx + sinp * dy
    y1p = -sinp * dx + cosp * dy
    rx, ry = abs(rx), abs(ry)
    lam = x1p**2 / rx**2 + y1p**2 / ry**2
    if lam > 1:
        s = math.sqrt(lam)
        rx, ry = rx * s, ry * s
    num = rx**2 * ry**2 - rx**2 * y1p**2 - ry**2 * x1p**2
    den = rx**2 * y1p**2 + ry**2 * x1p**2
    co = math.sqrt(max(0, num / den)) if den else 0
    if large == sweep:
        co = -co
    cxp = co * rx * y1p / ry
    cyp = -co * ry * x1p / rx
    cx = cosp * cxp - sinp * cyp + (x0 + x1) / 2
    cy = sinp * cxp + cosp * cyp + (y0 + y1) / 2

    def ang(ux, uy, vx, vy):
        dot = ux * vx + uy * vy
        ln = math.hypot(ux, uy) * math.hypot(vx, vy)
        a = math.acos(max(-1, min(1, dot / ln))) if ln else 0
        if ux * vy - uy * vx < 0:
            a = -a
        return a

    th1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dth = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and dth > 0:
        dth -= 2 * math.pi
    elif sweep and dth < 0:
        dth += 2 * math.pi
    for k in range(1, n + 1):
        th = th1 + dth * k / n
        x = cosp * rx * math.cos(th) - sinp * ry * math.sin(th) + cx
        y = sinp * rx * math.cos(th) + cosp * ry * math.sin(th) + cy
        yield (x, y)


def sample(tokens):
    """Yield all on-curve sample points for bbox."""
    cur = (0, 0)
    start = (0, 0)
    for cmd, nums in tokens:
        rel = cmd.islower()
        c = cmd.upper()
        i = 0

        def pt(ax, ay):
            return (ax + cur[0], ay + cur[1]) if rel else (ax, ay)

        if c == "M":
            while i < len(nums):
                p = pt(nums[i], nums[i + 1])
                yield p
                cur = p
                if i == 0:
                    start = p
                i += 2
        elif c == "L":
            while i < len(nums):
                p = pt(nums[i], nums[i + 1])
                yield p
                cur = p
                i += 2
        elif c == "H":
            while i < len(nums):
                x = nums[i] + (cur[0] if rel else 0)
                cur = (x, cur[1])
                yield cur
                i += 1
        elif c == "V":
            while i < len(nums):
                y = nums[i] + (cur[1] if rel else 0)
                cur = (cur[0], y)
                yield cur
                i += 1
        elif c == "C":
            while i < len(nums):
                p1 = pt(nums[i], nums[i + 1])
                p2 = pt(nums[i + 2], nums[i + 3])
                p3 = pt(nums[i + 4], nums[i + 5])
                for q in cubic(cur, p1, p2, p3):
                    yield q
                cur = p3
                i += 6
        elif c == "S":
            while i < len(nums):
                p2 = pt(nums[i], nums[i + 1])
                p3 = pt(nums[i + 2], nums[i + 3])
                for q in cubic(cur, cur, p2, p3):
                    yield q
                cur = p3
                i += 4
        elif c == "Q":
            while i < len(nums):
                p1 = pt(nums[i], nums[i + 1])
                p2 = pt(nums[i + 2], nums[i + 3])
                for q in quad(cur, p1, p2):
                    yield q
                cur = p2
                i += 4
        elif c == "T":
            while i < len(nums):
                p2 = pt(nums[i], nums[i + 1])
                yield p2
                cur = p2
                i += 2
        elif c == "A":
            while i < len(nums):
                rx, ry, rot, la, sw = nums[i:i + 5]
                p1 = pt(nums[i + 5], nums[i + 6])
                for q in arc_points(cur, rx, ry, rot, int(la), int(sw), p1):
                    yield q
                cur = p1
                i += 7
        elif c == "Z":
            cur = start


def transform_path(tokens, s, tx, ty):
    """Bake uniform scale + translate into absolute coordinates."""
    out = []
    cur = (0, 0)
    start = (0, 0)

    def ax(x):
        return x * s + tx

    def ay(y):
        return y * s + ty

    def fmt(v):
        return f"{v:.3f}".rstrip("0").rstrip(".")

    for cmd, nums in tokens:
        rel = cmd.islower()
        c = cmd.upper()
        i = 0
        if c == "M":
            parts = []
            while i < len(nums):
                p = (nums[i] + (cur[0] if rel else 0), nums[i + 1] + (cur[1] if rel else 0))
                parts.append(f"{fmt(ax(p[0]))} {fmt(ay(p[1]))}")
                cur = p
                if i == 0:
                    start = p
                i += 2
            out.append("M" + "L".join(parts) if False else "M" + " ".join(parts))
        elif c == "L":
            parts = []
            while i < len(nums):
                p = (nums[i] + (cur[0] if rel else 0), nums[i + 1] + (cur[1] if rel else 0))
                parts.append(f"{fmt(ax(p[0]))} {fmt(ay(p[1]))}")
                cur = p
                i += 2
            out.append("L" + " ".join(parts))
        elif c == "H":
            while i < len(nums):
                x = nums[i] + (cur[0] if rel else 0)
                cur = (x, cur[1])
                out.append(f"L{fmt(ax(x))} {fmt(ay(cur[1]))}")
                i += 1
        elif c == "V":
            while i < len(nums):
                y = nums[i] + (cur[1] if rel else 0)
                cur = (cur[0], y)
                out.append(f"L{fmt(ax(cur[0]))} {fmt(ay(y))}")
                i += 1
        elif c in ("C", "S", "Q", "T"):
            while i < len(nums):
                if c == "C":
                    coords = nums[i:i + 6]
                    i += 6
                elif c in ("S", "Q"):
                    coords = nums[i:i + 4]
                    i += 4
                else:
                    coords = nums[i:i + 2]
                    i += 2
                pts = []
                for j in range(0, len(coords), 2):
                    p = (coords[j] + (cur[0] if rel else 0), coords[j + 1] + (cur[1] if rel else 0))
                    pts.append(p)
                last = pts[-1]
                seg = c + " ".join(f"{fmt(ax(p[0]))} {fmt(ay(p[1]))}" for p in pts)
                out.append(seg)
                cur = last
        elif c == "A":
            while i < len(nums):
                rx, ry, rot, la, sw = nums[i:i + 5]
                p = (nums[i + 5] + (cur[0] if rel else 0), nums[i + 6] + (cur[1] if rel else 0))
                out.append(
                    f"A{fmt(rx * s)} {fmt(ry * s)} {fmt(rot)} {int(la)} {int(sw)} "
                    f"{fmt(ax(p[0]))} {fmt(ay(p[1]))}"
                )
                cur = p
                i += 7
        elif c == "Z":
            out.append("Z")
            cur = start
    return "".join(out)


def main():
    robot = open(ROBOT).read()
    prefix = robot.split('  <g id="Symbols">')[0]
    # Drop the robot's provenance comment; each brand gets its own below.
    prefix = re.sub(r"<!--.*?-->\n", "", prefix, count=1, flags=re.DOTALL)

    for src, name, descname, fillrule, provenance in BRANDS:
        header = (
            "<!--\n"
            f"  {provenance}\n\n"
            "  Fitted into the SF Symbols template (Template v.7.0) via\n"
            "  apple/bin/make-brand-symbols.py from the source SVG in\n"
            "  apple/bin/brand-symbol-sources/: the single logo path is uniformly\n"
            "  scaled and centered in the cap-height box at the Ultralight,\n"
            "  Regular, and Black 'Small' anchors (same artwork in each; Xcode\n"
            "  interpolates the remaining weights), so it renders, scales, and\n"
            "  tints like a native SF Symbol.\n"
            "-->\n"
        )
        svg = open(os.path.join(SOURCES, src)).read()
        ds = re.findall(r'd="([^"]+)"', svg)
        assert len(ds) == 1, f"{src}: expected 1 path, got {len(ds)}"
        tokens = tokenize(ds[0])
        pts = list(sample(tokens))
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        minx, maxx, miny, maxy = min(xs), max(xs), min(ys), max(ys)
        w, h = maxx - minx, maxy - miny
        cx, cy = (minx + maxx) / 2, (miny + maxy) / 2
        s = FIT_BOX / max(w, h)

        # insert brand provenance after the XML declaration, set descriptive name
        out = prefix.replace("?>\n", "?>\n" + header, 1).replace(
            ">Generated from android-robot<", f">Generated from {descname}<"
        )
        fr = f' fill-rule="{fillrule}"' if fillrule else ""
        out += '  <g id="Symbols">\n'
        for layer in ("Black-S", "Regular-S", "Ultralight-S"):
            anchor_x = ANCHORS[layer]
            tx = anchor_x - cx * s
            ty = CAP_MID - cy * s
            d = transform_path(tokens, s, tx, ty)
            out += f'   <g id="{layer}">\n    <path{fr} d="{d}"/>\n   </g>\n'
        out += "  </g>\n</svg>\n"

        dest_dir = os.path.join(ASSETS, f"{name}.symbolset")
        os.makedirs(dest_dir, exist_ok=True)
        fname = descname + ".svg"
        with open(os.path.join(dest_dir, fname), "w") as f:
            f.write(out)
        with open(os.path.join(dest_dir, "Contents.json"), "w") as f:
            f.write(
                '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  },\n'
                '  "symbols" : [\n    {\n      "filename" : "'
                + fname
                + '",\n      "idiom" : "universal"\n    }\n  ]\n}\n'
            )
        print(f"{name}: bbox {w:.1f}x{h:.1f} scale {s:.2f} -> {dest_dir}")


if __name__ == "__main__":
    main()
