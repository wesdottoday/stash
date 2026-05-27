# stash

A high-performance macOS utility for ubiquitous capture. Global hotkey, paste and/or type, Enter. Done.

stash eliminates the friction between "I want to keep this" and "it's on disk." It requires zero mental energy and becomes an invisible part of your daily workflow.

## What it does

- Press a hotkey from anywhere in macOS
- A small input window appears instantly
- Paste or type whatever you want to keep
- Hit Enter — content lands in your configured destination folder
- Text and URLs become markdown files with YAML front matter
- Images and files drop as bare files unless accompanied by text

## Performance targets

| Metric | Budget |
|--------|--------|
| Hotkey to window paint | < 50ms |
| Enter to file written | < 100ms |
| RSS at idle (1 hour) | < 10MB |
| RSS after 100 captures | < 20MB |
| CPU at idle | < 0.1% |
| Bundle size | < 5MB |
| Cold launch to ready | < 200ms |

## Install

**Requires macOS 13 (Ventura) or later.**

### Download

Grab the latest DMG from [Releases](https://github.com/wesdottoday/stash/releases), open it, and drag stash.app to Applications.

### Build from source

```bash
git clone https://github.com/wesdottoday/stash.git
cd stash
make
make install   # copies to /Applications
```

## Architecture

- Native macOS, system frameworks only (AppKit, Foundation, ApplicationServices, Network)
- Zero external dependencies
- Resident daemon with pre-created hidden NSPanel
- Single `.app` bundle, no installer

## Configuration

All preferences are accessible via the menu bar dropdown or the command line:

```bash
# Destination folder
defaults write com.wesdottoday.stash destinationFolder "/path/to/folder"

# Save confirmation
defaults write com.wesdottoday.stash confirmationEnabled -bool true
defaults write com.wesdottoday.stash confirmationDuration -int 100

# Image normalization
defaults write com.wesdottoday.stash imageNormalization -bool true

# Re-enable menu bar icon
defaults write com.wesdottoday.stash menuBarEnabled -bool true
```

## License

MIT — see [LICENSE](LICENSE).

We don't collect any data.
