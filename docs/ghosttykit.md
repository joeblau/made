# GhosttyKit binary artifact

Pilot consumes Ghostty's internal embedding API through a checksummed SwiftPM
binary target. Normal clones do not download the old 566 MB of raw Git LFS
archives; SwiftPM fetches one stripped, compressed XCFramework from the
`ghosttykit-1.3.1-blau.2` GitHub release.

## Provenance

- Official upstream: <https://github.com/ghostty-org/ghostty>
- Tag: `v1.3.1`
- Annotated tag object: `22efb0be2bbea73e5339f5426fa3b20edabcaa11`
- Commit: `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`
- Required Zig: Homebrew `0.15.2_1`, which adds Xcode 26.4+ Darwin TBD
  matching to upstream Zig 0.15.2
- blau artifact release: `ghosttykit-1.3.1-blau.2`

The immutable packaging commit and script hashes, upstream commit and tag
object, Xcode version, canonical Zig/Homebrew dependency receipts, Zig binary
hash, architectures, header-tree hash, artifact hashes and sizes, budgets, and
SwiftPM checksum are recorded in `GhosttyKit.release.json` beside each release
artifact.

`apple/Patches/ghostty-v1.3.1-xcframework-only.patch` changes only upstream
packaging. It removes the independent `libghostty-vt` host dylib from Zig's
default install step because that dylib is not part of GhosttyXCFramework. It
also uses Zig's LLVM archiver in deterministic Darwin `qL` mode to flatten the
static dependencies without relying on Apple `libtool`'s handling of Zig
Mach-O archive members. The patch
does not alter GhosttyKit source code, compiler flags, headers, or object code;
its SHA-256 is included in the release metadata.

## Reproduce the release

The authoritative path is the manually dispatched
`GhosttyKit Pinned Release Candidate` workflow on a `macos-26` runner:

```bash
gh workflow run ghosttykit-bootstrap.yml \
  --ref ghosttykit-1.3.1-blau.2
```

It installs the checksummed Homebrew formula from the recorded homebrew/core
commit, builds Zig 0.15.2_1 from source against pinned major LLVM/LLD formulae,
records canonical dependency receipts, builds GhosttyKit twice from empty
source/cache roots, compares all five outputs byte-for-byte, and uploads the
candidate without publishing it. To run the packager locally, reproduce the
workflow's pinned Zig installation, then record and pass its provenance:

```bash
provenance="$(mktemp)"
apple/bin/write-ghosttykit-zig-provenance.sh "$provenance"
GHOSTTYKIT_ZIG_PROVENANCE_FILE="$provenance" \
  apple/bin/package-ghosttykit.sh build
```

The script fetches only the pinned official tag, verifies both tag object and
peeled commit, applies the audited build-graph-only patch, runs upstream's
universal XCFramework build in `ReleaseFast`,
preserves the unstripped libraries/symbol bundles separately, strips runtime
debug symbols with Apple's `strip -S`, refreshes archive indexes, and creates
normalized ZIPs in `release-artifacts/ghosttykit-1.3.1-blau.2/`.

Before producing checksums it fails unless:

- the macOS slice contains arm64 and x86_64;
- iOS device and simulator slices contain arm64 and have distinct platform
  declarations;
- all slices have identical headers and import the explicit `GhosttyKit`
  module without incomplete-umbrella warnings;
- required public embedding symbols remain in every advertised architecture;
- consumers compile and link for macOS arm64 and x86_64, iOS arm64, and iOS
  Simulator arm64, and the host macOS consumer runs successfully;
- the expanded runtime is at most 128 MiB and its ZIP is at most 40 MiB;
- expanded symbols are at most 640 MiB and their ZIP is at most 160 MiB.

GhosttyKit contains static libraries, so the XCFramework itself is not code
signed. The final Pilot application is the signing boundary; a signed archive
and installed-app launch are release checks after SwiftPM resolves the binary.

## Publish and update

1. Compare a second clean build's runtime, symbols, license, metadata, and
   checksum manifest byte-for-byte.
2. Create an annotated `ghosttykit-1.3.1-blau.2` tag at the exact packaging
   revision recorded in the metadata, then create its release.
3. Upload `GhosttyKit.xcframework.zip`, `GhosttyKit.symbols.zip`,
   `LICENSE.ghostty`, `GhosttyKit.release.json`, and
   `GhosttyKit.checksums.txt` without renaming.
4. Put `swift package compute-checksum GhosttyKit.xcframework.zip` in
   `apple/Packages/GhosttyKit/Package.swift`.
5. Regenerate `apple/made.xcodeproj`, resolve packages from a clean cache, run
   `apple/bin/build-ci.sh` and `apple/bin/test.sh pilot`, then archive and launch
   the signed Pilot app.

The symbols ZIP is for maintainers and crash investigation only. Do not add it
to SwiftPM or a normal checkout.

## History and LFS

Removing the tracked LFS pointers stops future clones from fetching those
objects for the current tree, but it does not remove historical LFS storage or
Git history. Any server-side LFS cleanup or history rewrite is a separate,
explicit migration that must coordinate with every contributor; this process
does not perform one.
