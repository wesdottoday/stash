# stash

A high-performance macOS utility for ubiquitous capture, and the hub of the Stash ecosystem. Global hotkey, paste and/or type, Enter. Done — or hold a chord and just talk.

stash eliminates the friction between "I want to keep this" and "it's on disk." It requires zero mental energy and becomes an invisible part of your daily workflow.

## What it does

- Press a hotkey from anywhere in macOS
- A small input window appears instantly
- Paste or type whatever you want to keep
- Hit Enter — content lands in your configured destination folder
- Text and URLs become markdown files with YAML front matter
- Images and files drop as bare files unless accompanied by text

### Voice capture

- Press the **voice chord** (default `⌃⌥⌘V`) from anywhere — a small toast slides in and recording starts in the background while you keep working
- The toast shows a red dot, an elapsed timer, and a rolling one-line live transcript; the menu-bar icon turns into a red record dot
- **Press the chord again, or click Stop, to save. Press Escape to discard.**
- You get two files in your destination folder: a lossless **ALAC `.m4a`** and a matching **WebVTT** transcript, transcribed **on-device** (no network, no upload)
- Recording survives sleep and crashes — the working file is finalized on the next launch

### Sync (the hub role)

stash can act as the **hub** of the Stash ecosystem: it holds a connection to a self-hosted [stash-relay](https://github.com/wesdottoday/stash-relay), receives captures other devices (e.g. an iPhone) posted, decrypts them, and writes them into your vault — and posts its own captures back so other clients stay current.

- **Zero-knowledge:** captures are end-to-end encrypted (AES-256-GCM). The relay only ever sees opaque blobs; stash is the sole decryptor and vault-writer.
- **No data loss across sleep:** stash is a laptop, so it's often asleep or offline. Captures wait in the relay and drain when stash next wakes, stamped with their **original capture time**, never duplicated.
- Sync is **off until you enroll** — see [Enrolling with a relay](#enrolling-with-a-relay) below.

## Performance targets

| Metric | Budget |
|--------|--------|
| Hotkey to window paint | < 50ms |
| Enter to file written | < 100ms |
| Window dismiss to focus restored | < 16ms |
| CPU at idle | < 0.1% |
| Bundle size | < 5MB |
| Cold launch to ready | < 200ms |
| RSS at idle | ≈ 75MB (see note) |

> **Idle RSS note.** The original capture-only app targeted < 10MB. Voice + sync link in large system frameworks (AVFoundation, Speech), so idle RSS is now ~75MB — much of it shared, clean framework pages rather than dirty heap. The hot-path latency budgets are unchanged: all voice/sync work runs off the capture hot path. See [`DECISIONS.md`](DECISIONS.md) for the full re-baseline.

## Install

**Requires macOS 26 (Tahoe) or later.** (Voice uses the on-device `SpeechAnalyzer`, which is macOS 26+.)

### Download

Grab the latest DMG from [Releases](https://github.com/wesdottoday/stash/releases), open it, and drag stash.app to Applications.

### Build from source

```bash
git clone https://github.com/wesdottoday/stash.git
cd stash
make
make install   # copies to /Applications
```

On first voice capture, macOS will ask for **Microphone** and **Speech Recognition** permission.

## Architecture

- Native macOS, **system frameworks only** — AppKit, Foundation, AVFoundation, Speech, CryptoKit, Security (Keychain), Network, CoreAudio, CoreImage
- Zero external dependencies; single Swift target built with `swiftc` via a `Makefile`
- Resident menu-bar daemon with a pre-created hidden capture `NSPanel` (and a pre-created voice toast panel)
- Single `.app` bundle, no installer, no helper processes

See [`DECISIONS.md`](DECISIONS.md) for the design rationale and [`PLAN.md`](PLAN.md) for the build roadmap.

## Enrolling with a relay

Sync requires a running [stash-relay](https://github.com/wesdottoday/stash-relay). Enrollment is QR / deep-link based and the end-to-end encryption key never transits the relay.

1. **First device (this Mac):** on the relay host, run `stash-relay enroll <name>`. It prints a `stash://enroll?...` URL (and a terminal QR). Open the URL on this Mac (click it, or run `open "stash://enroll?..."`). stash claims a device key, **generates the encryption key, and becomes its custodian.**
2. **Additional devices (e.g. iPhone):** open **Preferences ▸ Sync ▸ Link a device…** on this Mac. It shows a QR carrying a one-time token **and** the encryption key. Scan it with the other device's Camera.

Preferences shows the live sync state: `Enrolled with <host>`, connection status, items waiting, and last-drain age.

## Configuration

All preferences are accessible via the menu bar dropdown or the command line:

```bash
# Destination folder (the vault inbox)
defaults write com.wesdottoday.stash destinationFolder "/path/to/folder"

# Capture hotkey (key code + raw NSEvent.ModifierFlags bitmask)
defaults write com.wesdottoday.stash hotkeyKeyCode -int 44          # default: /
defaults write com.wesdottoday.stash hotkeyModifiers -int 1572864   # ⌃⌥⌘

# Voice hotkey
defaults write com.wesdottoday.stash voiceHotkeyKeyCode -int 9      # default: V
defaults write com.wesdottoday.stash voiceHotkeyModifiers -int 1572864

# Save confirmation
defaults write com.wesdottoday.stash confirmationEnabled -bool true
defaults write com.wesdottoday.stash confirmationDuration -int 100

# Image normalization
defaults write com.wesdottoday.stash imageNormalization -bool true

# Re-enable menu bar icon
defaults write com.wesdottoday.stash menuBarEnabled -bool true
```

The relay base URL is captured during enrollment (`relayBaseURL`); the device API key and the encryption key live in the **Keychain**, not in defaults.

## Privacy

- Voice transcription is **100% on-device** (Apple's Speech framework). Audio never leaves your machine except, if you enroll, as an **end-to-end-encrypted** blob to your own relay.
- No analytics, telemetry, or phone-home. The only logging is to the system's unified log (no log files); payloads and keys are never logged.

## License

MIT — see [LICENSE](LICENSE).

We don't collect any data.
