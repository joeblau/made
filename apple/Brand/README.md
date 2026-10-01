# App icon source and export

`AppIconMaster.png` is the single authoritative 1024×1024 opaque sRGB source
for Cockpit, Walkie, Kneeboard, and Trigger. Its SHA-256 is
`43621e02055dce6da8352f2b7184d1f9d5aeb907511782d815ebb191e0c2662f`.

Regenerate every catalog slot and the iOS dark/tinted appearances with:

```bash
apple/bin/app-icon-tool.swift generate
apple/bin/app-icon-tool.swift validate
```

The generator renders into explicit sRGB, opaque bitmaps and uses high-quality
downsampling. Validation checks every manifest reference, point-size/scale,
alpha, RGB color model, target selection, and the 8% platform-mask safe area.
CI runs the same validation before compiling the apps.

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
