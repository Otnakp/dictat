# Dictat

Native macOS **push-to-talk dictation** in the menu bar. Like Wispr Flow, but **free, local, open source**.
Hold a key, speak, release: the transcription (Apple Speech, on-device) is pasted into whatever text
field is focused automatically.

No cloud, account, OpenAI/Whisper, Electron/Python. Only public Apple APIs that already works perfectly on your computer. Auto updates, and cool permission flow with
[Sparkle](https://sparkle-project.org) and
[Permiso](https://github.com/zats/permiso).

Lives only in the menu bar. All code in one file:
[`Dictat/Dictat.swift`](Dictat/Dictat.swift).

---

## Install

### Homebrew (recommended)

```bash
brew tap Otnakp/dictat            # adds the Otnakp/homebrew-dictat tap
brew install --cask dictat
```

### Manual

Download `Dictat.zip` from the [latest release](https://github.com/Otnakp/dictat/releases/latest),
unzip, and drag `Dictat.app` to `/Applications`.

---

## Usage

1. Launch → a `mic` icon appears in the menu bar.
2. Click it and grant the permissions (see below).
3. Two ways to dictate, both always on:
   - **Hold** the key, speak, release → pastes on release.
   - **Double-press** the key to start hands-free, **double-press** again to stop and paste.
4. The text is pasted into the active app (Safari, Chrome, Notes, TextEdit, ChatGPT, …).

Set the key with **Change…** (any modifier or key — modifiers and F13–F20 work best; a
printable key gets swallowed while it's the hotkey). The language picker (🇮🇹/🇬🇧) switches both
the recognition and the whole UI; default is English.

---


## Recognition

- `SFSpeechRecognizer` for the selected locale (`it-IT` / `en-US`), on-device preferred.
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


## Troubleshooting

- **Hotkey only works when Dictat is focused** → grant **Input Monitoring**.
- **Doesn't paste** but text is on the clipboard → grant **Accessibility**, or paste manually.
- **Permission toggle won't stick** → stale TCC entries; `tccutil reset Accessibility com.otnakp.dictat` and re-grant.
- **"On-device unavailable"** → the language model isn't installed; turn off "on-device only".
- Some terminals block synthesized paste; copy from the popover and paste manually.

## Notes

Local app: no telemetry, no cloud. With on-device recognition the audio never leaves your Mac.
The clipboard is overwritten with the dictated text (no automatic restore).

MIT licensed — see [LICENSE](LICENSE).
