# SPIKE 0.1.0 — installation preview

Status: public installation preview, tag `v0.1.0-preview.2`, app version 0.1.0 / build 2. Own code/documentation use MIT. [Download this preview](https://github.com/kirilldodon2-ux/SPIKE/releases/tag/v0.1.0-preview.2). This document describes the current feature set and limits, not a claim of general release readiness.

## Changed in preview.2

- The owner’s Pulse app icon is compiled from its saved Icon Composer source, with native light/dark appearances and a compiler-generated compatibility icon.
- The repository header uses light/dark exports of the same design.
- Installation links and release status now describe the public preview. The personal `do.png` image and runtime features are unchanged.

The earlier `v0.1.0-preview.1` release and its assets remain available as history.

## Included

- Compact hover surface with Now Playing and Mirror.
- Music-priority source selection, local controls and an audio-reactive ASCII visual.
- Click-to-photo and hold-to-video with explicit microphone use and local files.
- Deep SPIKE appearance, system colours, transparency, Rainbow, experimental Liquid Glass, personal image and effects.
- Bounded audio cleanup retries and an audio quit deadline independent of video finalisation.

## Checked and remaining

Owner UX on M3 Pro, deterministic self-checks, synthetic JPEG/MOV, audio fault scenarios, real Metal, source/candidate notices and ad-hoc signatures have been checked. The owner reported successful launch and reopening from Applications after the macOS app-specific exception; the exact profile/package context is still being clarified. The full browser installation checklist, macOS grants/update behaviour and broad hardware/OS compatibility remain open. Video saving was confirmed by the owner; live sound and recovery scenarios are not fully established.

The DMG contains the rebuilt candidate packaged on 2026-10-07, using SDK 26.5 and Xcode 27’s icon compiler. Compilation, the complete existing self-test, native icon variants in the asset catalog, ad-hoc signing and mounted DMG byte comparison passed; one independent packaging review found no actionable issues. Native Finder appearance on other OS versions is not verified. This icon update does not establish a fix for the undiagnosed earlier Finder launch failure. DMG SHA-256: `042c553f997adc7afec4d87908fcea9027bb3fa25087bb81020537d74af65761`.

The binary is arm64. Metadata minOS14 is a build floor, not a complete support matrix. System audio needs14.2+, native Glass26+. There is no Developer ID/notarization, automatic updater or launch-at-login function. The app-specific macOS exception is system-controlled; a previous generic Finder launch failure on another Mac remains undiagnosed.

The system-media helper is experimental and uses undocumented behaviour. Apple Music favourite saving is present but live-library verification remains open. Persistent audio HAL failure can retain resources until termination; a quit deadline is not proof of every kernel operation succeeding. Mirror recovery, fullscreen/Spaces/multiple displays and some keyboard/accessibility interactions need further hardware checks.

Mirror light remains disabled. Artwork-colour themes and additional features are not part of this preview.

[Install](INSTALL.md) · [Build](BUILD.md) · [Permissions](PRIVACY.md) · [Notices](../THIRD_PARTY_NOTICES.md)
