# Mock-ups section

Cockpit's **Mock-ups** sidebar section (below Runners) is a studio for device
mock-ups built on Apple's own 3D device models. Photo and Video share one
document: the background, the canvas aspect ratio, the device and its finish,
the layout, the pose, and a separate screenshot for each device in the layout.

- **Photo** renders a still. You set the pose with Turn, Tilt, Rotation, Size
  and, for hinged devices, Open. Export is a PNG 3000 px on the long side. It
  has a transparent background when the backdrop is set to None.
- **Video** plays an editable keyframe timeline. Motion presets (Turntable,
  Hero Tilt, Float, Open & Reveal, Flip In, Slide Up and Still) generate an
  initial timeline; changing a keyframe or transition makes it Custom. Export
  is a social-ready MP4 (see below).

Code is in `apple/Sources/Pilot/Mockups/`. The live stage and both exports
render the same SceneKit scene. One pure timeline evaluator supplies every
preview and exported frame, so their poses match exactly.

## Device layouts

The left rail has a device picker, finish swatches, and a scrolling layout
gallery. It selects a distinct catalog for each device family, matching the
[PostSpark device editor](https://postspark.app/device-mockup) reviewed on
2026-11-07. Thumbnails are drawn locally; no PostSpark artwork or device frames
are used.

| Supported device | Reference checked | Layout catalog |
|---|---|---|
| iPhone 18 Pro | iPhone 18 Pro | 19 phone layouts |
| iPhone 18 Pro Max | iPhone 18 Pro Max | 19 phone layouts |
| iPhone Duo | Duo Open and Duo Closed | 19 phone layouts in both states |
| iPhone Air | iPhone Air | 19 phone layouts |
| iPhone 17 | iPhone 17 | 19 phone layouts |
| iPhone 17e | Not listed in the reference picker | Adapted phone catalog |
| iPad Pro 13″ + Keyboard | iPad Pro 13 M4, also compared with iPad Pro 12.9 | 8 tablet layouts |
| MacBook Pro 14″ | MacBook Pro 14 Gen 5 | 7 laptop layouts |

- **Phone:** Centered, Angled, Top Detail, Top Close-up, Bottom Detail,
  Bottom Close-up, Side by Side, Staggered Pair, Overlapping Pair, Angled Pair,
  Fanned Pair, Split Pair, Three Across, Staggered Trio, Fanned Trio,
  Cascading Trio, Overlapping Trio, Center Hero, Angled Trio.
- **Tablet:** Centered, Angled, Top Aligned, Bottom Aligned, Side by Side,
  Overlapping Pair, Angled Pair, Fanned Pair. Tablet pairs use full-size
  devices with their own offsets and rotations; vertical alignment preserves
  device size instead of using the phone detail crops.
- **Laptop:** Centered, Left Close-up, Right Close-up, Left Edge, Right Edge,
  Bottom Aligned, Side by Side. Close-ups enlarge and lower the device;
  left/right edge layouts crop horizontally, and Bottom Aligned enlarges it
  by 20%. Wide-device fitting uses constant padding in device units so pairs
  span more of the canvas than singles, as in the reference.

**More layouts** separately offers Responsive Design (phone + MacBook),
adapted from the reference's template gallery. It uses the selected iPhone,
or iPhone 18 Pro when an iPad/Mac is selected. The iPad retains Cockpit's
bundled Magic Keyboard and Pencil. Android, desktop displays, watches, TVs,
and unbundled model generations are not added to the device catalog.

Choose a device on the canvas or use **Screen to edit** in the inspector,
then choose, drop, or paste its screenshot. Clear affects only that slot.
Switching to a smaller layout hides extra slots without discarding their
images. Switching layouts resets Turn, Tilt, Rotation, and Size, while keeping
the device, finish, backdrop, aspect ratio, images, and video motion. The last
layout is restored alongside the existing device/aspect preferences. Device
switches keep compatible selections and reset incompatible layouts to
Centered. Stale saved layouts also fall back to Centered; hidden screenshots
are retained in both cases.

`MockupLayout` defines device-relative positions, scale, rotation, and layer
ordering. The stage measures each loaded model's silhouette before fitting
the row to the canvas; an orthographic camera keeps spacing stable at each
depth. Close-ups deliberately extend beyond the artboard. Each instance owns
its model materials and hinge. Photo, live animation, and MP4 export all use
these same placements. Layout cards are schematic previews using the same
placement calculations and current backdrop/screenshots.

## Device models

Every device is Apple's unmodified public AR Quick Look model from its
apple.com product page. The models are checked in under
`apple/Sources/Pilot/Mockups/Models/`, so the app never downloads them at
runtime.

`apple/bin/fetch-mockup-models.sh` is the single authority for each model's
URL and SHA-256. `apple/bin/build-ci.sh`, and therefore CI, runs it with
`verify`, which also rejects any unpinned `.usdz` in that directory. Running it
with `fetch` re-downloads the models and refuses to install any file whose hash
doesn't match. If Apple replaces a file, update its URL and hash together in
one reviewed commit and re-run `MockupModelTests`.

| Device | Model file(s) | Finishes |
|---|---|---|
| iPhone 18 Pro, iPhone 18 Pro Max | `iphone-18-pro` (holds both phones) | Burgundy, Black, Glacier, Silver (USD variants) |
| iPhone Duo | Xcode's rigged `V68.usdz` at runtime; bundled `iphone-duo` as fallback | Star White, Night Sky (Light/Dark in the rig) |
| iPhone Air | `iphone-air` | Sky Blue (as published); Light Gold, Cloud White, Space Black retinted at load by `MockupRecolor` |
| iPhone 17 | `iphone-17` | Lavender |
| iPhone 17e | `iphone-17e-{soft-pink,white,black}` | one file per finish |
| iPad Pro 13″ | `ipad-pro-{space-black,silver}` | Apple only publishes it on the Magic Keyboard |
| MacBook Pro 14″ | `macbook-pro-14-space-black` (M5), `macbook-pro-14-silver` (M4, same chassis) | one file per finish |

How the loader (`MockupDeviceLibrary`) handles these files:

- **Retinting.** Apple publishes some models in one color. `MockupRecolor`
  scales flat materials and embedded textures that carry the authored body
  tone's color cast, channel by channel, onto the finish's body tone. Screens,
  glass, lenses, and neutral grays keep Apple's values, and the `.usdz` file is
  never modified. Texture bytes are read from the archive with a size bound.
- **Names.** Node and material names are scrambled and differ in every file,
  so the loader never looks anything up by name.
- **Screens.** A screen is a material whose emission is an image over a black
  diffuse. The loader crops each screenshot to the panel's measured aspect
  ratio. The iPad Pro's texture is stored rotated a quarter turn, so its
  screenshots are turned to match.
- **Orientation.** The loader fits a plane to the screen's vertices. The UVs
  can't be used for this because SceneKit indexes them separately from
  positions. It then aligns the screen to the minimum-area bounding rectangle,
  takes "up" as the in-plane axis nearest +Y, and treats the front as the side
  facing away from the housing.
- **Laptops and the iPad on its keyboard.** These are only rotated about the
  vertical axis, so their base stays level.
- **Variants.** SceneKit has no API for USD variants. The loader generates a
  small wrapper layer that references the bundled file and selects the
  variants. Variant names come only from the compiled-in catalog.
- **Multi-device files.** The iPhone 18 Pro file holds two phones. The loader
  keeps the one with the larger or smaller screen and removes the other.

## Hinges

- **MacBook Pro.** The M4 and M5 files have the lid baked open at 110°, with
  no hinge node. The loader inserts a hinge node at the measured pivot,
  (0, −0.09, −10.78) cm in Apple's file space, about +X, and moves the lid
  under it. Files that do author a lid rotation (around −110°) are driven
  through that node directly. `MockupModelTests` checks that closing the lid
  flattens the laptop.
- **iPhone Duo.** Apple's public AR file has only two baked poses, so the
  continuous fold comes from the rigged Duo model inside Xcode
  (`DeviceKit.framework/…/CoreDevicePopDeviceKitExtension.devicekitplugin/Contents/Resources/V68.usdz`).
  It has a 31-joint skeleton with a hinge chain under the inner screen.
  Cockpit never ships or copies this file. `DuoRig` loads it in place from the
  newest `/Applications/Xcode*.app` or `~/Applications/Xcode*.app`, and only
  if its SHA-256 matches the pinned version
  (`fd315e57c38fde5666d50de6e19b444e3d145450008126e85838119b682b7940`). The pin
  matters because the material names it relies on are specific to that
  version.
  - **How the fold is driven.** SceneKit imports the file's animation as one
    group of linear keyframe tracks. The loader samples the symmetric fold clip
    (frames 260 to 380 at 24 fps) and poses the joints directly, because
    SceneKit's own player stops evaluating once the nodes move into the
    stage's scene. An open amount maps to frame
    `260 + (180 − 180·open) / 1.5`.
  - **Fallback.** If no matching Xcode is installed, the Duo loads Apple's
    bundled AR model in the Landscape pose, and the Open control is hidden.

## Animation timeline

Video mode adds a native timeline below the canvas. Click the track to scrub;
click a diamond to select that pose. Turn, Tilt, Rotation, Move X, Move Y, Size
and Open then write into the selected keyframe. With no keyframe selected,
those controls change only the paused preview. Add captures the current pose
at the playhead, Delete removes the selected diamond, and the arrow buttons
step between keyframes. Dragging a diamond retimes it without changing the
movie's total length. Space toggles playback, the arrow keys scrub by one
frame (or one second with Shift), and Delete removes the selected keyframe.

Every keyframe owns the duration and cubic-Bézier easing of its outgoing
transition; the final duration is an end hold. Ease In & Out uses Rotato's
default control points (0.25, 0.1, 0.25, 1), with Linear, Ease In and Ease Out
also available. Changing duration changes the movie length. Timelines persist
in user defaults and are bounded to 256 keyframes and 120 seconds when loaded.
The model follows the locally inspected Rotato binary and its bundled keyed
archives: ordered poses, cumulative segment durations and per-segment Bézier
easing. No Rotato code or assets are bundled.

## Video export

The MP4 settings are the format that X, Instagram, TikTok, LinkedIn, Threads
and YouTube all accept without re-encoding problems:

- **Codec:** H.264 High, CABAC, 8-bit 4:2:0, BT.709 color tags.
- **Frame rate:** a constant 30 fps.
- **Size:** 1080 px on the short side, at most 1920 px on the long side, both
  dimensions even.
- **Bit rate:** about 0.2 bits per pixel per frame, around 12 Mbps at
  1080×1920.
- **Faststart:** the `moov` atom is placed before `mdat`, so the file can be
  streamed.
- **Length:** the exact sum of the keyframe transition durations and end hold.

## Untrusted input

Screenshots and background images come from drag and drop, the pasteboard, or
an open panel. `MockupImageLoader` handles all of them. It rejects files over
64 MB and images over 12,000 px on either side, and it reads the pixel size
from the image header before decoding anything.

## Licensing

- **Apple's AR models.** These are Apple marketing assets, shipped here at the
  maintainer's direction. They are used to depict Apple hardware, in the same
  way as the Mac mini in [runner-fleet-model.md](runner-fleet-model.md).
- **Apple Product Bezels** (developer.apple.com/design/resources). These are
  not bundled. Their license forbids embedding them in software or
  redistributing them, and allows mock-ups only of apps for Apple platforms.
- **Third-party 3D.** Sketchfab models licensed CC BY can be bundled with
  attribution. Models under "Free Standard" and BlenderKit licenses cannot,
  because the file can be extracted from the app bundle.
