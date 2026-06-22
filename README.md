# Dictat

Native macOS **push-to-talk dictation** in the menu bar — like Wispr Flow, but **free, local, open source**.
Hold a key, speak, release: the transcription (Apple Speech, on-device) is pasted into whatever text
field is focused via `NSPasteboard` + a synthesized `Cmd+V`.

No cloud, no account, no OpenAI/Whisper, no Electron/Python. Only public Apple APIs:
**Speech.framework**, **AVFoundation**, **NSPasteboard**, **CGEvent**. Plus
[Sparkle](https://sparkle-project.org) for auto-updates and a vendored copy of
[Permiso](https://github.com/zats/permiso) for the Accessibility-permission overlay.

Lives only in the menu bar — no Dock icon, no main window. All code in one file:
[`Dictat/Dictat.swift`](Dictat/Dictat.swift).

---

## Install

### Homebrew (recommended)

```bash
brew tap Otnakp/dictat            # adds the Otnakp/homebrew-dictat tap
brew install --cask dictat
```

The app is signed with a Developer ID and notarized, so it opens without Gatekeeper warnings.
Updates are handled in-app by Sparkle.

### Manual

Download `Dictat.zip` from the [latest release](https://github.com/Otnakp/dictat/releases/latest),
unzip, and drag `Dictat.app` to `/Applications`.

---

## Usage

1. Launch → a `mic` icon appears in the menu bar.
2. Click it and grant the permissions (see below).
3. **Hold** your push-to-talk key and speak.
4. Release → the text is pasted into the active app (Safari, Chrome, Notes, TextEdit, ChatGPT, …).

Icon reflects state: `mic` (idle) → `mic.fill` (recording) → `waveform` (transcribing).
The popover has the toggles, key/language pickers, last transcript, and *Check for Updates*.

### Push-to-talk key
- **Right Option ⌥** — default.
- **Fn / Globe** — works once Input Monitoring is granted.
- **Ctrl + Option ⌃⌥**.

---

## Permissions (one time)

The popover lists missing permissions with **Enable…** buttons. Accessibility & Input Monitoring use
a [Permiso](https://github.com/zats/permiso)-style overlay that floats over System Settings and lets you
drag the app into the list; it closes itself the moment the permission goes active.

| Permission | Needed for |
|---|---|
| **Microphone** | recording |
| **Speech Recognition** | transcription |
| **Accessibility** | synthesized `Cmd+V` (paste) |
| **Input Monitoring** | the **global** hotkey — without it the key only works while Dictat is focused |

---

## Recognition

- `SFSpeechRecognizer(locale: "it-IT")`, on-device preferred.
- If `supportsOnDeviceRecognition` → `requiresOnDeviceRecognition = true` (audio never leaves the device).
- `addsPunctuation = true`. "On-device only" toggle; clear error if the language model isn't installed.

---

## Build from source

Requirements: **macOS 14+ (Sonoma)**, **Xcode 15+**. Release build is universal (arm64 + x86_64).

```bash
open Dictat.xcodeproj      # scheme "Dictat", then Cmd+R
```

Debug builds are ad-hoc signed; sandbox is **off** (required for the global CGEvent tap and `Cmd+V`).
Sparkle is pulled automatically as a Swift Package dependency.

## Releasing

Signed + notarized release, signed Sparkle appcast, and GitHub release in one command:

```bash
# one-time: store notarization credentials in the keychain
xcrun notarytool store-credentials dictat-notary \
    --apple-id "you@example.com" --team-id C9AQ3WX79D --password "APP_SPECIFIC_PASSWORD"

./scripts/release.sh 1.0.0
```

The Sparkle EdDSA **public** key is in `Dictat/Info.plist` (`SUPublicEDKey`); the private key lives in
your login keychain. The Homebrew cask is [`Casks/dictat.rb`](Casks/dictat.rb) (lives in the
`Otnakp/homebrew-dictat` tap).

---

## Troubleshooting

- **Hotkey only works when Dictat is focused** → grant **Input Monitoring**.
- **Doesn't paste** but text is on the clipboard → grant **Accessibility**, or paste manually.
- **Permission toggle won't stick** → stale TCC entries; `tccutil reset Accessibility com.local.dictat` and re-grant.
- **"On-device unavailable"** → the language model isn't installed; turn off "on-device only".
- Some terminals block synthesized paste; copy from the popover and paste manually.

## Notes

Local app: no telemetry, no cloud. With on-device recognition the audio never leaves your Mac.
The clipboard is overwritten with the dictated text (no automatic restore).

MIT licensed — see [LICENSE](LICENSE).
