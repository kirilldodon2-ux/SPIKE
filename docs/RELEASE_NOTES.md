# SPIKE 0.1.0 — installation preview

Status: private installation test, tag `v0.1.0-preview.1`; own code/documentation use MIT. [Preview release](https://github.com/kirilldodon2-ux/SPIKE/releases/tag/v0.1.0-preview.1) requires repository access. No public release has been published; branding/assets review and downloaded first installation remain open. This document describes the current feature set and limits, not a claim of general release readiness.

## Included

- Compact hover surface with Now Playing and Mirror.
- Music-priority source selection, local controls and an audio-reactive ASCII visual.
- Click-to-photo and hold-to-video with explicit microphone use and local files.
- Deep SPIKE appearance, system colours, transparency, Rainbow, experimental Liquid Glass, personal image and effects.
- Bounded audio cleanup retries and an audio quit deadline independent of video finalisation.

## Checked and remaining

Owner UX on M3 Pro, deterministic self-checks, synthetic JPEG/MOV, audio fault scenarios, real Metal, source/candidate notices and ad-hoc signatures have been checked. External first installation, macOS grants/update behaviour and broad hardware/OS compatibility remain open. Video saving was confirmed by the owner; live sound and recovery scenarios are not fully established.

The DMG contains the same clean-tested candidate packaged on 2026-10-07. Preparing this private release changes delivery and documentation; it does not rebuild the app or fix the undiagnosed earlier Finder launch failure. SHA-256: `5e68298569f5b67fc47bc649250bac31adf53e57fc52c9c3840cb9955d912889`.

The binary is arm64. Metadata minOS14 is a build floor, not a complete support matrix. System audio needs14.2+, native Glass26+. There is no Developer ID/notarization, automatic updater or launch-at-login function. The app-specific macOS exception is system-controlled; a previous generic Finder launch failure on another Mac remains undiagnosed.

The system-media helper is experimental and uses undocumented behaviour. Apple Music favourite saving is present but live-library verification remains open. Persistent audio HAL failure can retain resources until termination; a quit deadline is not proof of every kernel operation succeeding. Mirror recovery, fullscreen/Spaces/multiple displays and some keyboard/accessibility interactions need further hardware checks.

Mirror light remains disabled. Artwork-colour themes and additional features are not part of this preview.

[Install](INSTALL.md) · [Build](BUILD.md) · [Permissions](PRIVACY.md) · [Notices](../THIRD_PARTY_NOTICES.md)
