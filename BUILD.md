# stash

Build a macOS app called "stash" — a zero-friction capture utility. It should require zero mental energy from the user and become an invisible part of their daily workflow. Global hotkey, paste and/or type text, Enter. Done.

Repository: https://github.com/wesdottoday/stash
License: MIT

---

## Interaction Flow

1. User presses the configured global hotkey from anywhere in macOS.
2. A small input window appears at the user's saved screen position (centered on first launch). The window contains a single text input field, focused and ready for input. A right-aligned hint inside the field reads "↵ to save."
3. User pastes content (Cmd+V) and/or types directly into the field. Once any keystroke is registered, the hint disappears.
4. The input field starts as a single line and grows up to six lines as content expands. Beyond six lines, the field scrolls internally. Shift+Enter inserts a newline. Enter submits. Escape cancels and dismisses the window without saving.
5. On submit, content is written to the configured destination folder according to the content handling rules below.
6. If save confirmation is enabled, a brief checkmark indicator appears (configurable duration, default 100ms) and the window dismisses. If disabled, the window dismisses immediately. The confirmation never requires user interaction to dismiss.
7. Focus returns to whatever application the user was in before the hotkey fired.
8. If a second hotkey press occurs while the window is open, it is ignored.
9. The hotkey must be available immediately after system wake with no re-registration delay.

---

## Content Handling

Content type is determined by what's in the input field and what's on the clipboard at submit time.

| Input | Output |
|-------|--------|
| Text only | Markdown file with front matter, text as body |
| URL only | Markdown file with front matter (`type: url`), body is `[url](url)`. Async background task fetches page title and updates to `[title](url)`. Silent failure on any fetch error. |
| Image only (paste) | Image file dropped directly in destination folder. No markdown file. Image is previewed inline in the input field before submit. |
| File only (paste) | File copied directly to destination folder. No markdown file. |
| Text + URL | Markdown file with front matter (`type: url`). User text preserved verbatim as body with URL detected inline, formatted as a markdown link. Async title fetch updates the link text. |
| Text + image (paste) | Markdown file with front matter. User text preserved verbatim as body. Image saved to `attachments/` subdirectory, markdown image reference appended below body: `![](attachments/filename.png)` |
| Text + file (paste) | Markdown file with front matter. User text preserved verbatim as body. File copied to destination, markdown link appended below body: `[filename](./filename.ext)` |
| File over 100MB (paste) | Warning displayed. Window remains open with text input field so the user can still capture a text note. |

In all cases where user-authored text is present, the text is stored verbatim — inline links, formatting, and structure are preserved exactly as typed.

### URL Detection

A URL is detected anywhere in the input text (http or https scheme, valid host). It does not need to be the entire input.

### URL Title Fetch

Background task with a 3-second connection timeout, 5-second total timeout, and 64KB response size cap. On success (HTTP 200 with a parseable `<title>` element), the file is updated in place. On any failure, the file is left as-is. No error surface, no retry.

### Image Handling

When the clipboard contains an image (PNG, TIFF, or other raster format), it is rendered as an inline preview in the input field on paste. If submitted with no text, the image is written directly to the destination folder. If submitted with text, the image is saved to an `attachments/` subdirectory and referenced via standard markdown image syntax.

### Image Normalization (preference toggle)

When enabled: filenames are stripped of spaces, and non-PNG/JPEG formats (e.g., WEBP, TIFF) are converted to PNG. No resizing. Must use built-in macOS frameworks (CoreGraphics, NSImage) — no external image processing libraries.

### File Handling

When the clipboard contains a file reference, the file is copied to the destination folder. Maximum file size: 100MB. Files over this limit trigger a warning and the window remains available for text input.

---

## File Naming

Markdown files: `YYYY-MM-DD-HHMMSS-<short-content-hash>.md`

The content hash is the first 6 hex characters of a SHA-256 of the file body. This ensures uniqueness across rapid captures.

Image files (when saved to `attachments/`): `YYYY-MM-DD-HHMMSS-<short-content-hash>.png` (or `.jpg`)

Copied files retain their original filename, normalized (spaces stripped) if the normalization preference is enabled.

---

## Front Matter

YAML front matter on all markdown files:

```yaml
---
created: 2026-05-27T10:22:00-04:00
type: text
source_app: Safari
tags: [nvidia/dgx, architecture]
---
```

- `created`: ISO 8601 timestamp with timezone offset at moment of submission.
- `type`: `text` or `url`.
- `source_app`: The application that was frontmost before the hotkey fired. NSPasteboard does not expose which app placed content on the clipboard, so this captures what the user was looking at when they decided to save — the best available signal. Omit if unavailable.
- `tags`: Extracted from `#hashtags` in the body. Nested tags with slashes (e.g., `#nvidia/dgx`) are captured as a single tag. Hashtags inside fenced code blocks and URLs are excluded. Tags remain in the body and are duplicated in front matter — this is intentional. Omit field if no tags found.

Front matter is only written on markdown files. Bare image and file drops have no front matter.

---

## Preferences

A standard macOS Preferences pane, accessible from the menu bar icon's dropdown menu. Single window, all settings visible at once.

1. **Destination folder.** Path picker (folder-select mode). Default: `~/_inbox`.
2. **Global hotkey.** Key-capture field. Default: `Ctrl+Opt+Cmd+/`.
3. **Save confirmation.** Toggle (on/off) and duration in milliseconds (range: 50–500, default: 100).
4. **Image normalization.** Toggle (on/off). When enabled, strips spaces from filenames and converts non-PNG/JPEG images to PNG. Default: enabled.
5. **Menu bar icon.** Toggle (on/off). Default: enabled. When disabled, a link to the GitHub repo README is shown, which documents all `defaults write` commands including how to re-enable the menu bar icon. There is no other UI path to preferences when the menu bar icon is disabled. This is intentional — the app is fully configurable via the command line.

At the bottom of the pane, in small but legible type: `We don't collect any data.` followed by a `source` link to https://github.com/wesdottoday/stash

---

## Menu Bar

When enabled, clicking the menu bar icon (mustache) shows:

- **Preferences...** (Cmd+,)
- **Quit** (Cmd+Q)

No "About" item. No update checker. No "Help." Static icon, no animation.

---

## First Launch

The preferences pane appears on first launch with all defaults pre-populated. No welcome screen, no onboarding flow, no tour. After the pane is dismissed, the app is silent and waits for the hotkey.

---

## Error Handling

- **Destination folder missing or unwritable.** Show the folder picker. Save to the new location and update the preference.
- **Image write fails.** If part of a markdown capture, write a placeholder note in the body. Front matter still written. If a bare image drop, show a brief error indicator.
- **URL fetch fails.** Silent. File stays in placeholder state.
- **Pasteboard read fails.** Treat as empty clipboard. Window still appears for typing.
- **File over 100MB.** Warning displayed, text input remains available.

---

## Persistence

Window position saved to preferences after each drag, restored on next activation. No other state between runs.

---

## What This App Does Not Do

- No Dock icon.
- No background indexing of captures.
- No tagging UI at capture time.
- No editing or browsing of past captures.
- No syncing.
- No analytics, telemetry, or phone-home behavior.
- No update checker.
- No notifications outside the in-app save confirmation.

---

## Performance Budgets

These are non-negotiable. The app either meets them or it has failed.

### Latency

- **Hotkey to window paint:** under 50ms. The hotkey response *is* the experience — any perceptible delay is a failure.
- **Enter to file written:** under 100ms.
- **Window dismiss to focus restored:** under 16ms (single frame at 60fps).

### Resources

- **RSS at idle:** under 10MB after 1 hour of running.
- **RSS after 100 captures:** under 20MB.
- **CPU at idle:** under 0.1% average over 10 minutes.
- **Application bundle size:** under 5MB.
- **Cold launch (first run after reboot):** under 200ms to ready-for-hotkey state.

---

## Architecture Requirements

- App runs as a resident daemon. The capture window is created at launch and held in memory as a hidden non-activating NSPanel. Hotkey activation shows the existing window via `orderFront`. The window is never destroyed and recreated during normal operation.
- No external dependencies beyond macOS system frameworks (AppKit, Foundation, ApplicationServices, Network). No third-party libraries. No package managers. Single Swift target.
- Single distributable binary in a standard `.app` bundle. No installer, no first-run script, no helper processes.
- Configuration written as a plist via `NSUserDefaults`, scriptable from the command line via `defaults write <bundle-id> <key> <value>`. README documents the full schema.
- No analytics, telemetry, or network calls except the URL title fetch on user-initiated URL captures.

The latency budget is the spec. If the window appears with any perceptible delay after the hotkey, the app has failed regardless of what else works.

Pick the implementation language. Pick the architecture. The budgets and behaviors above are non-negotiable. Everything else is your call.
