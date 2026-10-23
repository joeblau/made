# Cockpit feature screenshots

The native capture harness renders a catalog of fictional, populated workspaces
in light and dark mode. It is intended for landing-page feature images and design
mockups. No running Docker engine, GitHub account, agent session, remote computer,
or attached phone is needed.

## Capture

Use the repository's Xcode prerequisites from [README](../README.md). From the
repository root:

```sh
# List the scene IDs without building anything.
apple/bin/capture-pilot-scenes.py --list

# Build once, then export all 14 scenes in both appearances at 2×.
bun run screenshots:cockpit

# Iterate on selected scenes using the previous build.
apple/bin/capture-pilot-scenes.py --skip-build --scenes notes,actions,usage

# Change dimensions or capture just one appearance.
apple/bin/capture-pilot-scenes.py --scenes browser,device --appearance dark \
  --width 1600 --height 1000 --scale 2

# Export assets into the existing website's public directory.
apple/bin/capture-pilot-scenes.py \
  --output workers/web/public/screenshots/cockpit
```

The default destination is `apple/.build/snapshots/output/`. Open its `index.html`
to compare appearances and inspect images at full size. That directory is ignored
by Git; only intentionally exported website assets need to be checked in.

Default images are 2880 × 1920 pixels (1440 × 960 logical points). `--width`
accepts 1280–2560, `--height` 800–1600, and `--scale` 1 or 2. The desktop's own
appearance is not changed. Keep the same Xcode/macOS version for pixel comparisons;
native typography and controls can change between OS releases.

A successful run produces:

- `cockpit-<scene>-light.png` and `cockpit-<scene>-dark.png`.
- `manifest.json`, with the exact captured set, pixel dimensions, scale, alt
  text, and fixture date.
- `index.html`, a local review gallery with light/dark filters.

The script validates PNG dimensions and the complete requested scene matrix
before copying assets into the destination. A failed run leaves the previous
export intact. A partial run replaces the manifest with that run's subset;
previous PNGs and unrelated files are retained. Run the full catalog for a
complete website manifest. Build and capture logs live in
`apple/.build/snapshots/`; use `--derived-data` to choose another build cache.
`--skip-build` requires a successful earlier build and does not compile edits.

## Scenes

| Scene ID | Content |
| --- | --- |
| `workspace` | Two populated agent terminals, inspector closed |
| `editor` | Atlas API source and test results |
| `browser` | Orbit web preview beside an agent |
| `notes` | Release checklist, multiple tabs, and masked dummy configuration |
| `remote-desktop` | Four populated remote development screens |
| `docker` | Two Compose stacks, standalone services, and a stopped test container |
| `agentic-use` | Thirty days of cost, token, and cache data across five providers |
| `runners` | Eight macOS/Linux runners with idle, busy, and offline states |
| `actions` | Workflow successes and a failure in the inspector |
| `tasks` | Assigned project tasks in the inspector |
| `pull-requests` | Open and draft pull requests |
| `files` | A populated project file tree |
| `usage` | Five provider plan and credit cards |
| `device` | Web preview and a populated iPhone screen |

## What is real and what is a fixture

[SnapshotWorkbench](../apple/Tests/PilotTests/Snapshots/SnapshotWorkbench.swift)
composes the production Notes editor, Docker view, runner cards, usage
dashboard, and all five inspector panels. The capture-only sidebar, tab strips,
window chrome, and
terminal/editor/browser/remote/device surfaces are SwiftUI stand-ins. They show
fictional work; they are not live terminal emulation, browser rendering, VNC,
or device capture. This distinction lets screenshots remain useful without
starting processes or connecting to machines. The harness does not capture or
sanitize the user's existing desktop.

[SnapshotFixtures](../apple/Tests/PilotTests/Snapshots/SnapshotFixtures.swift)
contains the fictional Orbit and Atlas projects. It uses an in-memory SwiftData
container, an isolated preferences suite, fake Docker/runner/provider services,
fixed history dates, and no real credentials. Task ages and plan reset times are
omitted rather than tied to today's clock. The temporary preferences suite is
removed after each run.

Captures render an AppKit hosting hierarchy, which includes native scroll views
and the Notes text editor. SwiftUI `ImageRenderer` alone omits those surfaces.
Native glass and sidebar-selection effects require the window-server compositor;
the capture shell uses opaque equivalents so exported controls stay legible
without screen-recording permission or visible capture windows.
The capture test is skipped during normal unit tests unless the export script
supplies its output environment. Catalog and fixture validation still run in the
normal macOS test suite.

## Add or change a scene

1. Add a stable case, caption, and selection to
   [SnapshotCatalog](../apple/Tests/PilotTests/Snapshots/SnapshotCatalog.swift).
2. Add its deterministic data to `SnapshotFixtures` and composition to
   `SnapshotWorkbench` or
   [SnapshotSurfaces](../apple/Tests/PilotTests/Snapshots/SnapshotSurfaces.swift).
3. Regenerate and capture without `--skip-build`. Review both appearances in the
   gallery, especially text wrapping, chart labels, and scroll boundaries.
4. Update the catalog-count assertion in
   [LandingSnapshotTests](../apple/Tests/PilotTests/Snapshots/LandingSnapshotTests.swift)
   and the scene table above.

The CLI reads scene IDs from the Swift catalog so its list and validation use
one authoritative source. Keep new service dependencies injectable; fixtures
must never fall through to a live client.

## Embed on the landing page

After exporting to `workers/web/public/screenshots/cockpit`, use the reachable
[`CockpitScreenshot`](../workers/web/src/components/CockpitScreenshot.astro)
component from a feature section. The site requires every source component to be
reachable from a page; [the example](examples/CockpitScreenshot.astro) mirrors
the production component for reference:

```astro
---
import CockpitScreenshot from './CockpitScreenshot.astro';
---
<CockpitScreenshot
  scene="runners"
  alt="Cockpit showing an eight-machine development runner fleet"
/>
```

The component follows the operating system by default and the site's manual
light/dark selection after the theme controller initializes. It respects the
`/made` base path, reserves the image's aspect ratio, and lazy-loads by default.
For a hero image use `loading="eager"`; for custom capture dimensions pass the
actual pixel `width` and `height`.

The generated `index.html` gallery is a local review artifact, not a website
page. Its inline filter script violates the website's Content Security Policy,
so it must not be copied into the deployable site; the website uses only the
PNG captures and `manifest.json`. The default local gallery remains available
under `apple/.build/snapshots/output/`.
