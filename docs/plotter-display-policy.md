# Plotter display and multitasking policy

Plotter supports iPad multitasking and all four interface orientations. It is
not a full-screen-only app. This is a deliberate product decision: keeping a
live Pilot mirror beside Xcode, documentation, or a conferencing app is a core
iPad workflow, including Split View and Stage Manager window sizes.

`apple/Sources/Plotter/Info.plist` therefore declares portrait, upside-down
portrait, landscape left, and landscape right. Do not add
`UIRequiresFullScreen` merely to suppress an archive warning.

The video and PencilKit canvas always share one transform. The unzoomed video
uses an aspect-fit rectangle calculated from the current window bounds, and
annotations travel over the wire as normalized coordinates relative to that
rectangle. Stroke width is normalized the same way, as a fraction of the
rectangle's shorter side, and the wire format accepts only that normalized
range. Rotation, Split View, Stage Manager resizing, and external display
resizing therefore change only the local projection; they do not change an
annotation's location on the mirrored Mac content.

## Release checks

1. Run `apple/bin/build-ci.sh` and confirm no orientation validation warning.
2. Run `apple/bin/test.sh shared` for portrait, landscape, and split-view
   coordinate round-trip coverage.
3. Run Plotter's `testMirrorRemainsUsableAcrossRotation` UI test on an iPad
   simulator.
4. Before App Store submission, exercise portrait, landscape, 1/2 Split View,
   and a Stage Manager window on a physical iPad while drawing across the
   mirror's letterboxed edges.
