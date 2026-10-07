# Build SPIKE

Build on macOS with the Apple Swift toolchain and macOS SDK. The package declares Swift tools 6.0 and a macOS 14 floor; the current release candidate was checked with SDK 26.5. Native Glass compilation needs a toolchain/SDK containing the macOS 26 APIs. Older SDKs and Intel builds are not verified. Swift Package dependencies are empty; helper source is included locally.

## Development app

From the repository root:

```sh
./spikes/surface-engine/build.command
open './spikes/surface-engine/output/ONE Surface Spike.app'
```

The build compiles Swift and the helper, runs the existing deterministic self-checks and signs the app ad-hoc. It does not launch it. Quit an existing instance before launching a rebuilt app. Historical output names and bundle ID `local.one.surface-spike` are intentional.

## Release candidate and DMG

Use an explicit SDK installed on your Mac. The tested SDK path was `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`; SDK availability differs between machines.

```sh
./spikes/surface-engine/build.command --release-candidate /absolute/path/to/MacOSX.sdk
./spikes/surface-engine/package-preview.command
```

The release build writes `output/ONE Release Candidate.app`, whose Finder name is SPIKE. The packaging command uses that already-built candidate, verifies its signature/metadata/architecture and creates a DMG with SPIKE.app, Applications and START.txt plus a checksum. It does not launch the app or alter the working debug app. A selected root LICENSE, if present, is also included as LICENSE.txt; without one, the result remains a local licensing draft.

The default DMG path is `spikes/surface-engine/output/SPIKE-0.1.0-preview-arm64.dmg` for the current candidate. Existing outputs are not overwritten. Supply a new absolute `.dmg` path for another package, or validate the candidate without packaging:

```sh
./spikes/surface-engine/package-preview.command --check
./spikes/surface-engine/package-preview.command /absolute/path/SPIKE-test.dmg
```

The package script uses standard macOS tools. Disk-image creation/mounting needs the system disk-image service; a restricted agent sandbox may not expose it.

## Verification

```sh
'spikes/surface-engine/output/ONE Release Candidate.app/Contents/MacOS/ONESurfaceSpike' --self-test
codesign --verify --deep --strict 'spikes/surface-engine/output/ONE Release Candidate.app'
```

Self-checks cover deterministic geometry/media/identity logic, synthetic photo/video, audio failure scenarios and Metal. They require working system media codecs/GPU access, but do not start a live camera, microphone or audio tap. Successful compilation alone is not a passed self-check. These checks do not prove another Mac's first launch, native permissions or subjective motion/feel.

[Install](INSTALL.md) · [Preview limits](RELEASE_NOTES.md) · [Notices](../THIRD_PARTY_NOTICES.md)
