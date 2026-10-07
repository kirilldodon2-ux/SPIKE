# Data and permissions

SPIKE's current application is local. It has no account, telemetry, cloud sync or application network upload. Source apps such as Spotify and the browser still operate independently and can use the network.

| Feature | Access | Data handling |
| --- | --- | --- |
| Mirror preview | Camera, on explicit entry | Local mirrored preview; no automatic photo/video |
| Photo | Same camera permission; save-folder access if needed | JPEG on Desktop or the chosen folder |
| Video | Camera; microphone only for explicitly started recording | Local MOV with sound in the same folder; short click stops |
| Audio visual | Combined output audio of the Mac | Bounded samples analysed in memory; no PCM/audio recording files or upload |
| Music/Spotify priority and controls | Local Automation to the running source app | Track/state read; controls only through user actions; Music favourite through explicit click |
| Other Now Playing metadata | Fixed bundled offline Perl/helper experiment | Source/title/artist/artwork; disableable, undocumented system integration |
| Personal image/settings | Selected local file and app preferences | Owned local identity copy and preferences outside the app bundle |

The visual is enabled by default but captures only while expanded Now Playing is visible and the visual/accessibility gates allow it. Collapse, Mirror or disabling requests a stop on the worker queue. Cleanup retries are bounded; persistent HAL failure/stall may retain handles until process termination. This is not a claim of unconditional immediate release.

Video recording holds Mirror open. Explicit hide/mode change finishes the clip and requests camera stop. Quit waits for video finalisation independently of the audio deadline. Real permission/error/recovery behaviour is not proven on every device.

SPIKE does not use the Photos library API. macOS grants for camera, microphone, system audio, Automation and protected folders remain separate. Declining a grant limits the related feature rather than authorising a substitute capture path. Ad-hoc builds can cause repeat permission requests when code identity changes.

Diagnostic errors may reach the local system log; malformed media-helper replies can include media metadata. “Local” does not mean “no logs”. Do not publish unreviewed logs containing private track/session information.

The preview is not App Sandbox-entitled and has not undergone a comprehensive security certification. Permissions describe actual feature paths, not a security badge.

[Install](INSTALL.md) · [Preview limits](RELEASE_NOTES.md)
