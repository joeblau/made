# Runner fleet 3D assets

Cockpit's **3D Fleet** runner layout draws each Mac runner with Apple's public
Mac mini AR model and labels the hub with the GitHub mark. Both files are
checked in so the app never downloads assets at runtime.

## Mac mini model

- File: `apple/Sources/Pilot/Runners/MacMini.usdz`, bundled unmodified.
- Source: Apple's AR Quick Look model from the Mac mini product page,
  <https://www.apple.com/105/media/us/mac-mini/2026/2140fd43-1461-420d-942c-6f254535a9a4/ar/mac-mini-silver.usdz>
- SHA-256: `3d36f189975cb24e2614e1aadabc1ae6112c8a298722c2eabc67f56a4d986ace`
- Dimensions: native centimetres, 12.7 × 5.0 × 12.7 (Apple's published
  127 × 50 × 127 mm), front face toward +z.

`apple/bin/fetch-runner-model.sh` is the single authority for the URL and hash.
`apple/bin/build-ci.sh`, and so CI, runs `apple/bin/fetch-runner-model.sh
verify`; `fetch` re-downloads the file and refuses to install it unless the
hash matches. If Apple replaces the file,
update the URL and hash together in one reviewed commit and re-run the fleet
model tests.

At runtime Cockpit merges the model's meshes by material into one shared
template, so each runner costs about 19 draw calls instead of 74. SceneKit's
`flattenedClone()` cannot do this: it returns an empty geometry for the file's
multi-channel polygon elements. The aluminium is re-tuned (lighter, partly
diffuse) so the fleet's overhead key brightens the lids while the sides stay
dark. Apple's export scrambles node names, so the
status light is located by geometry: the only tiny flat disc on the front face.
`RunnerFleetTests` fails if the bundled model stops yielding exactly one.

The file is Apple's marketing asset. It is used here only to depict the Mac
minis that run CI, the same way Apple's product imagery is used to identify its
hardware; do not ship it in other contexts without checking Apple's terms.

## GitHub mark

`apple/Sources/Pilot/Assets.xcassets/GitHubMark.imageset/GitHubMark.svg` is
the 16 px `mark-github` path from GitHub's MIT-licensed Octicons, used to
identify GitHub as the runners' control plane per GitHub's logo guidelines.
