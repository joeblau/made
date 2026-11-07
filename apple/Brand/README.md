# App icon sources

Cockpit, Kneeboard, and Walkie use distinct native **Icon Composer** documents.
The fighter-flight family uses centered silhouettes, broad low-poly facets,
cyan/cobalt glass, and coral/amber signals. The documents contain editable SVGs
and native materials; lighting, shadows, refraction, and platform masks are
rendered by Apple.

| Product | Xcode target | Source | Depth groups / SVG layers |
| --- | --- | --- | --- |
| Cockpit · macOS | `Pilot` | [Cockpit.icon](Icons/Cockpit.icon/) | 4 / 8 |
| Kneeboard · iPadOS | `Plotter` | [Kneeboard.icon](Icons/Kneeboard.icon/) | 4 / 7 |
| Walkie · iPhone | `Copilot` | [Walkie.icon](Icons/Walkie.icon/) | 4 / 5 |
| Drone · worker | `droned` is a command-line tool | [Drone.icon](Icons/Drone.icon/) | 4 / 4 |

The first three targets include their `.icon` as a resource and select its name
through `ASSETCATALOG_COMPILER_APPICON_NAME` in `apple/project.yml`. Xcode compiles
the document for each platform and size. Drone has no application icon slot;
its source is ready for future use. Trigger (`Wingman Watch App`) retains the
legacy catalog icon. All four new sources support circular watchOS previews.

## Layer structure

Groups are listed from back to front here; Icon Composer serializes them in the
opposite order. Every transparent SVG shares a 1024×1024 artboard and origin.

| Icon | 01 · Structure | 02 · Facets | 03 · Glass / surface | 04 · Signals |
| --- | --- | --- | --- | --- |
| Cockpit | Shell, canopy field | Canopy and frame | Instrument glass, HUD | Horizon, heading chevron, control stick |
| Kneeboard | Board silhouette | Frame | Chart glass | Harness buckles, clip, navigation arcs, heading marker |
| Walkie | Chassis and antenna | Housing | Display | Speaker grille, amber transmit key |
| Drone | Aircraft silhouette | Wings and tail | Fuselage | Nose sensor |

The background is a native gradient, with dark and monochrome overrides.
Opaque structural layers preserve the silhouette. Glass is enabled on facets,
screens, hardware, and signals where it helps separate surfaces. Fine markings
such as the horizon, chart arcs, and grille stay solid. Per-group translucency,
specular highlights, and restrained neutral shadows add depth without baking
lighting into the SVGs. Per-layer monochrome fills preserve tonal separation.

## Edit and regenerate

Open a document directly in Apple's app, from the repository root:

```bash
open -a "Icon Composer" apple/Brand/Icons/Cockpit.icon
```

The hand-authored geometry in [build-icon-layers.py](../bin/build-icon-layers.py)
is the authoritative source for the 24 SVGs. It reconstructs the latest symmetry
study as separate shapes; it is not a pixel-exact extraction of the concept PNGs.
Edit that script to change shapes and regenerate:

```bash
python3 apple/bin/build-icon-layers.py
```

Each checked-in `icon.json` is authoritative for materials, group order,
placement, backgrounds, and appearance overrides. Edit these properties in Icon
Composer and save normally. Regeneration preserves existing `icon.json` files,
so material tuning survives. Direct edits to generated SVGs must also be made
in the geometry script. The generator's material defaults only initialize a
missing document; they do not overwrite a saved one.

## Validate, render, and compile

```bash
apple/bin/app-icon-tool.swift validate
python3 apple/bin/composer-icons.py render
python3 apple/bin/composer-icons.py compile
```

Validation checks SVG reproducibility and artboards, source references, native
depth groups and appearances, and every generated app build configuration's
resource membership and icon selection. The existing CI icon check runs this
validation alongside the legacy catalog checks.

Rendering uses Icon Composer's bundled `ictool` and exports default, dark,
clear/light, clear/dark, tinted/light, tinted/dark, and watchOS previews for all
four icons into `icons/composer/previews`. These previews and their layer manifest
feed the optional local layer gallery. Tinted previews use the renderer's sample
purple tint; users choose their own system tint.

Compilation uses Apple's `actool` with each app's real asset catalog and `.icon`
source. It checks the emitted `CFBundleIconName` and `Assets.car`. Compiler output
is kept in ignored `apple/.build/icon-validation`. This verifies the asset lane;
it does not build or launch the full Swift applications.

The `icons/` directory contains temporary studies and previews. The production
sources and validation remain under `apple/`, so removing the temporary folder
does not affect application builds.

Apple documents this workflow in
[Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
and [Say hello to Icon Composer](https://developer.apple.com/videos/play/wwdc2025/361/).

## Legacy raster source

`AppIconMaster.png` remains the authoritative 1024×1024 opaque sRGB source for
Trigger and the retained, unselected `AppIcon` catalogs in the other three apps.
Its SHA-256 is `43621e02055dce6da8352f2b7184d1f9d5aeb907511782d815ebb191e0c2662f`.

Regenerate both the native SVG geometry and legacy catalog slots with:

```bash
apple/bin/app-icon-tool.swift generate
apple/bin/app-icon-tool.swift validate
```

The legacy generator renders opaque sRGB bitmaps with high-quality downsampling.
Legacy validation checks manifest references, point-size/scale, alpha, RGB color
model, and the original master's 8% platform-mask safe area.

## Original generation prompt

The master was created once with Codex's built-in image generation tool, then
resized to 1024×1024 and assigned the sRGB IEC61966-2.1 profile. No third-party
logo or source image was used.

```text
Use case: logo-brand
Asset type: authoritative 1024×1024 Apple app icon master for macOS, iOS/iPadOS, and watchOS
Primary request: Create an original production-grade icon for “blau,” a native Apple developer cockpit that unifies terminal, browser, devices, screen mirroring, plotting, and a watch companion. Build a single bold abstract cockpit/window mark from four connected panes around a subtle central axis; it should suggest a lowercase b without using a literal letter.
Scene/backdrop: edge-to-edge square canvas with a deep near-black charcoal background (#08090B), a very subtle warm radial glow, and no pre-rounded outer corners
Style/medium: precise minimal geometric 3D/flat hybrid, Apple-platform app icon polish, crisp at 16 px, restrained depth, no photorealism
Composition/framing: centered compact emblem occupying about 62% of the canvas; all essential detail inside the central 80% safe area; generous breathing room
Lighting/mood: focused, technical, calm, premium
Color palette: dominant charcoal and graphite; one warm amber/orange signal (#FF8A3D) and one vivid terminal green signal (#2EE88A); soft off-white only for tiny structural highlights
Materials/textures: satin dark metal or glass with extremely restrained gradients; clean hard edges
Constraints: opaque RGB artwork; one icon only; no text; no letters; no numbers; no watermark; no brand or third-party logos; no device mockup; no border; no outer rounded rectangle; no transparent areas; strong silhouette; remain legible when reduced to 16×16
Avoid: blue as a dominant color, busy detail, thin line art, tiny symbols, excessive glow, neon cyberpunk styling, bevel-heavy skeuomorphism, shadows extending beyond the central safe area
```
