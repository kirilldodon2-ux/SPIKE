# Install SPIKE preview

This preview is built for **Apple Silicon**. Open the public [preview release](https://github.com/kirilldodon2-ux/SPIKE/releases/tag/v0.1.0-preview.2) and download **SPIKE-0.1.0-preview.2-arm64.dmg** from Assets. Do not choose the automatically generated source-code ZIP/TAR files for installation.

1. Open the SPIKE DMG.
2. Drag **SPIKE.app** onto the **Applications** shortcut. Quit an older SPIKE before replacing it.
3. Open SPIKE from Applications. You can eject the DMG afterwards.

SPIKE appears at the top of the screen without a permanent Dock or menu-bar icon. Hover to expand; right-click → settings. Quit using its right-click menu.

## Check the first installation in a new macOS profile

1. Quit SPIKE in your original macOS account, then switch to the new account.
2. In that account's browser, download the DMG from the public release above. Do not copy the local project app or its DMG into the profile for this check.
3. Install and open the downloaded app as described above. If Finder asks for an administrator's password when copying into Applications, use the normal macOS prompt.
4. Note the first-launch message and whether **Open Anyway** appears when needed. Once launched, check hover expansion/collapse and open Deep SPIKE.
5. Enter Mirror explicitly, allow the camera if you want to test it, and take one photo. Quit through SPIKE's menu, then reopen the same installed app. No microphone grant is needed for a photo.
6. Report the macOS version, the first-launch result, and whether photo saving and reopening worked. If launch fails, keep the exact message; no serial number is needed.

This checks browser delivery, installation and a new user's settings/permissions on this Mac. It does not establish another Mac's compatibility or guarantee a completely fresh Gatekeeper state: the hardware, operating system and some system state are shared. [Apple's launch-testing guidance](https://help.apple.com/xcode/mac/current/en.lproj/dev1cc22a95c.html).

## If macOS stops the first launch

The preview has an ad-hoc signature, without Developer ID/notarization. After attempting to open it, an unverified-developer warning may offer the app-specific exception in **System Settings → Privacy & Security → Open Anyway**. The system controls whether that option appears. [Apple's instructions](https://support.apple.com/en-us/102445).

If the only message is “The application can't be opened” and no exception appears, this is a different, currently undiagnosed launch failure. Do not disable Gatekeeper globally. If convenient, report the exact error and macOS version; a serial number is unnecessary.

## Permissions

Camera access is requested when you enter Mirror. Microphone access is requested only when you explicitly begin a video. The visual may request access to the Mac's combined output audio. Music/Spotify Automation is requested through the explicit permission action while the player is running. Desktop/folder saving can need its own permission. One installer agreement cannot replace these macOS decisions. [Details](PRIVACY.md).

## Update

Quit SPIKE, download the new DMG, replace the app in Applications and reopen it. Preferences live outside the app bundle. With an ad-hoc rebuild, macOS permissions may be requested again; persistence of every grant is not guaranteed. Automatic updating and launch at login are not included in this preview.

[Preview limits](RELEASE_NOTES.md) · [Home](../README.md)
