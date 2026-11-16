# SPIKE 0.1.0 — installation preview

Public installation preview `v0.1.0-preview.3`, app version 0.1.0, build 3. SPIKE’s own code and documentation use MIT. [Download this preview](https://github.com/kirilldodon2-ux/SPIKE/releases/tag/v0.1.0-preview.3).

## Changed in preview.3

- Tighter spacing around the expanded panel, with the same artwork size.
- A Now Playing timeline with elapsed time and duration for sources that provide both. Click or drag to seek in Spotify and Apple Music when the running player has macOS Automation access.
- Artwork decoding runs off the UI thread. SPIKE retains the current Spotify cover across transient metadata gaps during play and pause.

[Preview 2 with the Pulse icon](https://github.com/kirilldodon2-ux/SPIKE/releases/tag/v0.1.0-preview.2).

## Included

- Compact hover surface with Now Playing and Mirror.
- Music-priority source selection, local controls and an audio-reactive ASCII visual.
- Click-to-photo and hold-to-video with explicit microphone use and local files.
- Deep SPIKE appearance, system colours, transparency, Rainbow, experimental Liquid Glass, personal image and effects.
- Bounded audio cleanup retries and an audio quit deadline independent of video finalisation.

## Checked and remaining

Owner UX on M3 Pro, deterministic self-checks, synthetic JPEG/MOV, audio fault scenarios, real Metal, source/candidate notices and ad-hoc signatures have been checked. The owner reported successful launch and reopening from Applications after the macOS app-specific exception; the exact profile/package context is still being clarified. The full browser installation checklist, macOS grants/update behaviour and broad hardware/OS compatibility remain open. Video saving was confirmed by the owner; live sound and recovery scenarios are not fully established.

Preview 3 uses SDK 26.5 and Xcode 27’s icon compiler. The release candidate passed the complete self-test and signature checks. The mounted DMG was checked against that candidate. The owner verified the Spotify cover fix in the development app. Live seeking and Apple Music timeline behavior still need hardware verification. The DMG checksum is available in the release assets.

The binary is arm64. Metadata minOS14 is a build floor, not a complete support matrix. System audio needs14.2+, native Glass26+. There is no Developer ID/notarization, automatic updater or launch-at-login function. The app-specific macOS exception is system-controlled; a previous generic Finder launch failure on another Mac remains undiagnosed.

The system-media helper is experimental and uses undocumented behaviour. Apple Music favourite saving is present but live-library verification remains open. Persistent audio HAL failure can retain resources until termination; a quit deadline is not proof of every kernel operation succeeding. Mirror recovery, fullscreen/Spaces/multiple displays and some keyboard/accessibility interactions need further hardware checks.

Mirror light remains disabled. Artwork-colour themes and additional features are not part of this preview.

[Install](INSTALL.md) · [Build](BUILD.md) · [Permissions](PRIVACY.md) · [Notices](../THIRD_PARTY_NOTICES.md)
