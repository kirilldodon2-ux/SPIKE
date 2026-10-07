<div align="center">
  <img src="spikes/surface-engine/Sources/ONESurfaceSpike/Resources/do.png" width="56" alt="SPIKE identity">
  <h1>SPIKE</h1>
  <p>Music on the left. Mirror on the right.</p>
  <p>A small, personal surface at the top of your Mac.</p>
</div>

SPIKE stays compact while you work. Hover to open your current music or a local camera mirror; move away to tuck it back. Two everyday functions, with your own image and appearance.

## Two sides

**Now Playing** shows the selected source, artwork and controls, with an audio-reactive ASCII visual. Playing music has priority over browser media and incidental playback. Spotify and Music can be read through local Automation; other system metadata uses a disableable experimental helper.

**Mirror** provides a mirrored camera preview. Click for a local photo, hold to start video with microphone sound, then click to stop. Photos and videos go to Desktop or a folder you choose.

**Deep SPIKE** changes the live surface: colour, transparency, Rainbow, system colours, experimental Liquid Glass, your PNG/JPEG/GIF, and identity effects. The ordinary black material remains the default. Mirror light is disabled.

## Install the preview

The Apple Silicon candidate is being tested in a private repository. [Download the installation preview](https://github.com/kirilldodon2-ux/SPIKE/releases/tag/v0.1.0-preview.1) while signed in to a GitHub account with repository access, then choose **SPIKE-preview-2026-10-07-arm64-mit.dmg** under Assets. The automatically generated source-code ZIP/TAR files are for developers, not app installation. There is no public download yet.

1. Open the DMG and drag **SPIKE.app** to **Applications**.
2. Launch SPIKE from Applications.
3. If macOS shows an unverified-developer warning, follow its app-specific **Open Anyway** flow. This preview is ad-hoc signed, without Developer ID/notarization.

You do not need Xcode or a terminal to install the app. [Installation, first launch and the new-profile check](docs/INSTALL.md).

## Current compatibility

| Item | Preview status |
| --- | --- |
| Binary | Apple Silicon / arm64; Intel is not verified |
| Hardware | Main UX tested by the owner on a MacBook Pro M3 Pro |
| Minimum OS | Build metadata says macOS 14; this is not a tested support matrix |
| System audio visual | Requires macOS 14.2+ and its system permission |
| Native Liquid Glass | macOS 26+; ordinary material fallback on unsupported/accessibility configurations |
| External installation | Still to be verified on another Mac |
| Updates / launch at login | Manual update; launch at login is not implemented |

The experimental system-media helper relies on undocumented MediaRemote behaviour and may stop working after a macOS update. Source-app permissions and platform failures can affect individual features. [Preview notes](docs/RELEASE_NOTES.md).

## Local by design

SPIKE has no account, telemetry or application network upload. Camera use is explicit; the microphone is added only for a video recording you start. The visual analyses the Mac's combined output audio in memory, without PCM files. macOS controls permissions separately. Some diagnostic errors can include media metadata; this is not a claim that nothing is ever logged. [Data and permissions](docs/PRIVACY.md).

## Build and development

Swift + AppKit + SwiftUI, with Metal for the visual. No external Swift Package dependencies; the small media helper is vendored with its notice.

[Build from source](docs/BUILD.md) · [Documented development history](docs/HISTORY.md) · [Third-party notices](THIRD_PARTY_NOTICES.md)

Historical ONE names remain in paths and the bundle identifier. The product name is SPIKE.

## Licence

SPIKE's own code and project documentation use the [MIT licence](LICENSE). Existing third-party terms remain in force; see [notices](THIRD_PARTY_NOTICES.md). Branding/assets rights and reuse remain a separate review before public publication; the code licence is not a claim of ownership of third-party artwork or music.

SPIKE / dodon.one
