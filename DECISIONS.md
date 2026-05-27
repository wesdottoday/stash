# Design Decisions

This document explains the implementation choices behind stash, and how they
satisfy the spec in `BUILD.md`. The non-negotiable items in the spec — latency
budgets, resource budgets, no third-party dependencies, single Swift target —
shaped every decision below.

## Language and toolchain

**Swift, compiled with `swiftc` via a Makefile.**

The spec demands native macOS, AppKit-only, no package managers, single Swift
target, and a small single binary. Swift is the natural choice: it has direct
bridging to every Cocoa API I need, and the standard system Swift runtime ships
with macOS 12+, so the binary doesn't have to embed it.

I chose a Makefile over SwiftPM or an Xcode project because:

- SwiftPM is technically a package manager. Even with zero dependencies, it
  introduces `Package.swift` and the `.build/` cache, which feels like exactly
  the kind of indirection the spec is rejecting.
- An Xcode project would bury the build configuration in `.pbxproj` files that
  are unreadable in diff form.
- A `Makefile` that invokes `swiftc` directly is honest: every flag is visible,
  and `make` is the build interface. There is also a `universal` target that
  compiles arm64 + x86_64 slices and `lipo`s them together for distribution.

The targeted minimum is macOS 12.0 — recent enough that `CryptoKit`,
`UniformTypeIdentifiers`, and modern AppKit conveniences are available without
fallbacks, but not so recent that it locks out a still-supported segment of
users.

## Framework set

The spec lists "AppKit, Foundation, ApplicationServices, Network" as the allowed
system frameworks. The implementation uses, in addition to those:

- **CryptoKit** — for SHA-256 (`ContentHash.swift`). The spec requires "first 6
  hex characters of a SHA-256." CryptoKit is the modern Apple-native SHA
  implementation; CommonCrypto would be the older alternative. CryptoKit is a
  macOS system framework, not a third-party dependency, and the choice between
  the two is a wash. I picked CryptoKit because it's simpler and statically
  typed.
- **CoreGraphics / ImageIO / UniformTypeIdentifiers** — for image format
  detection and PNG conversion (`ImageNormalizer.swift`). The spec requires
  using "built-in macOS frameworks (CoreGraphics, NSImage)" for image
  normalization. ImageIO is the lower-level companion to CoreGraphics for
  reading/writing image formats; both are part of the same `CoreGraphics.framework`
  / `ImageIO.framework` umbrella. UniformTypeIdentifiers gives me the canonical
  `UTType.png.identifier` string that `CGImageDestination` requires.
- **Carbon (HIToolbox)** — for `RegisterEventHotKey`. This is the load-bearing
  framework choice. The spec asks for a global hotkey "available immediately
  after system wake with no re-registration delay" and "the hotkey response *is*
  the experience." There are three ways to get a global hotkey on macOS:
  1. `RegisterEventHotKey` (Carbon HIToolbox) — intercepting, no permissions
     required, available immediately.
  2. `NSEvent.addGlobalMonitorForEvents` — monitoring only, does not intercept;
     the keystroke still goes through to whatever app was frontmost.
  3. `CGEventTap` — intercepting, but requires the user to grant Accessibility
     permissions in System Settings.

  Option 2 is wrong because the keystroke would leak into whatever app was
  frontmost. Option 3 is wrong because the spec wants "zero mental energy from
  the user" — being prompted to grant Accessibility is the opposite of that, and
  the prompt would be the very first thing a new user saw. So Carbon is the
  only viable option. I'm reading the spec's parenthetical framework list as
  illustrative rather than exhaustive, since Carbon is plainly a macOS system
  framework. This is the most important deviation from the literal text of the
  spec, and it's documented here so the choice is visible.

  Carbon is also used in `KeyCaptureField.swift` for the `kVK_*` virtual key
  constants. These are just integer literals dressed up as constants, but using
  the named ones is more readable than hard-coding `44` for `/`.

No third-party libraries, no SPM dependencies, no Homebrew tools. `swiftc` is
the only required toolchain piece beyond the OS.

## Hot path: hotkey to window paint

The spec budget is **under 50ms** for hotkey-to-paint, and it is explicit that
"the hotkey response *is* the experience." So the design centres around making
that path do almost nothing at activation time:

- The `CaptureWindow` (an `NSPanel`) is **created during
  `applicationDidFinishLaunching`**, populated with its `CaptureView` subviews
  laid out, and never destroyed until the app quits. Hotkey activation calls
  `prepareForShow()` (which clears state but reuses the existing views) and
  `makeKeyAndOrderFront(nil)`. No view allocation, no layout-from-scratch, no
  bitmap re-rasterisation.
- The panel uses `styleMask: [.borderless, .nonactivatingPanel]` with
  `animationBehavior = .none`. Borderless avoids the title-bar
  composition costs; `.nonactivatingPanel` is the whole reason the focus
  restoration story works at all (see below); and disabling animation means
  `orderFront` paints synchronously rather than fading in over ~150ms.
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`
  so the window appears on whichever Space and screen the user is currently on,
  including over full-screen apps, without dropping the user out of their
  current Space.
- The Carbon hotkey event handler dispatches the callback **synchronously** to
  the main thread (since Carbon application-event-target handlers already run
  on the main thread for Cocoa apps). I do not bounce through
  `DispatchQueue.main.async`, which would add a runloop tick.

The `pendingSourceApp` (frontmost app at hotkey time) is captured **before**
`makeKeyAndOrderFront`, because a non-activating panel does not change
`NSWorkspace.shared.frontmostApplication`, but I would rather not rely on that
ordering by accident.

## Focus restoration (under 16ms budget)

The spec budget for window-dismiss-to-focus-restored is one frame. This is
solved structurally rather than algorithmically: because the capture panel is a
`.nonactivatingPanel`, our app never takes activation away from the user's
previous app. The previous app remains the frontmost application throughout the
capture flow. On `orderOut(nil)`, the panel disappears and the user is already
looking at the previously-focused window — there is nothing to "restore." This
is also why `NSApp.setActivationPolicy(.accessory)` plus `LSUIElement=true` in
Info.plist matter: no Dock icon, no Cmd+Tab presence, no app-switcher
appearance for the capture window.

The one place we *do* call `NSApp.activate(ignoringOtherApps: true)` is when
the preferences window opens, because preferences is a real window the user
needs to interact with. That activation is intentional and scoped to that flow.

## Window resizing (1 → 6 lines, then internal scroll)

The capture text view starts at one line and grows to six lines as content is
added; beyond six lines the view scrolls internally. I implement this by
listening to `NSText.didChangeNotification` (`textDidChange` delegate method) on
the `CaptureTextView`, computing the new content height from the layout
manager, clamping it to `[1, 6] * line-height`, and resizing the window with
`setFrame(_:display:)`. The window anchors to its top edge so it grows
downward, which keeps the input under the user's cursor rather than chasing it
up the screen.

When the content exceeds six lines, the view's vertical scroller is enabled
and the window stops growing. This keeps the window from ever consuming a huge
slice of screen real estate.

## Image and file paste handling

The spec's content matrix distinguishes "image (paste)" from "file (paste)" —
they are different cases. The pasteboard inspection in
`CaptureView.handlePaste()` enforces this distinction:

1. **File URL** on the clipboard → treat as a file paste. Even if the file
   happens to be an image, it is copied as a file and (when text is present)
   referenced as a link in the markdown body — no inline image preview, no
   `attachments/` directory. This matches the "File only" and "Text + file"
   rows of the spec matrix.
2. **Raw image data** on the clipboard (PNG, TIFF, JPEG, etc., with no file
   URL — i.e. from Cmd+Shift+4 screenshots or screenshot utilities) → treat
   as an image paste, show the inline preview, save bare-or-attached per
   whether text was also entered.
3. **Otherwise** → fall through to the text view's normal paste, which inserts
   the plain text.

This was a small ambiguity in the spec — pasting an image file from Finder
could plausibly be either case. I chose the strict "what's on the pasteboard"
interpretation, which is the most predictable for the user.

The 100MB cap is checked **before** marking a file as the pending paste, so a
huge file paste shows the warning and leaves the window open with the text
input untouched, exactly as the spec describes.

## URL handling

`URLDetector.swift` uses `NSDataDetector` with the `link` checking type and
filters down to `http`/`https` schemes with non-empty hosts. Three cases are
distinguished:

- `isPureURL(_:)` — the input, after whitespace trimming, is *exactly* one URL
  with nothing else. Triggers the spec's "URL only" row: the body is rewritten
  to `[url](url)` and `type: url` is set in the front matter.
- A URL is present *somewhere* in the text — triggers "Text + URL". The body
  is preserved verbatim except that each detected URL is replaced with
  `[url](url)` via `wrapURLsAsMarkdownLinks`. URLs already inside an existing
  markdown link (preceded by `](`) are left alone, so typing
  `[my link](https://x.com)` doesn't get double-wrapped into nonsense.
- No URL — plain text, `type: text`.

When the type is `url`, an async title fetch runs on a separate `URLSession`
configured with `timeoutIntervalForRequest = 3` and `timeoutIntervalForResource
= 5`, matching the spec's "3-second connection timeout, 5-second total
timeout." The 64KB cap is enforced by truncating the received data before
parsing rather than by stopping the receive, which is the simpler and entirely
adequate implementation given the size involved.

On a successful fetch, the file is updated in-place by replacing the literal
`[url](url)` substring with `[title](url)`. The title has its `[` and `]`
characters defanged (to `(` and `)`) so it can't break the markdown link
syntax. If the user manually wrote their own markdown link with a different
display text, the literal `[url](url)` substring won't appear in the file, and
the title update silently no-ops — which is the right outcome.

## File naming and hashing

`YYYY-MM-DD-HHMMSS-<hash>.md` — the timestamp is built from a POSIX
`DateFormatter` (so locale doesn't perturb the format), the hash is the first
3 bytes (6 hex chars) of SHA-256 over the file body. The body is what gets
hashed, not the front matter — the front matter contains the timestamp, which
would make the hash trivially-unique-by-time and defeat the point. Hashing the
body means duplicate captures within the same second produce the same hash;
that's a reasonable signal that something is wrong.

For file copies, original filenames are preserved; if image-normalization is
enabled, whitespace in the filename is replaced with `-` (rather than stripped
outright — "my file.png" should become "my-file.png", not "myfile.png"). If a
naming collision occurs, a `-2`, `-3`, … suffix is appended before the
extension. The spec doesn't mention collision handling, but appending a numeric
suffix is the standard macOS-Finder-style approach and avoids losing data
silently.

## Front matter

YAML built by string concatenation in `FrontMatter.swift`, not by a YAML
library. This is the spec's "no third-party libraries" rule — and YAML is a
huge spec, but a single document with a known structure of scalars, an enum,
and a flow-sequence array is tiny to emit correctly.

`yamlScalar(_:)` quotes a scalar only when it needs to: empty, leading/trailing
whitespace, control characters, or any of the YAML flow indicators. Most
`source_app` values like `Safari` or `Visual Studio Code` come out unquoted,
which matches the spec's example. Hashtags from `HashtagExtractor` are
similarly unquoted in the common case.

`created` uses `ISO8601DateFormatter` with `.withInternetDateTime` and
`timeZone = TimeZone.current`, which produces `2026-05-27T10:22:00-04:00`
exactly as the spec example shows. Front matter is **only** written for
markdown captures; bare image/file drops have none, per the spec.

## Hashtag extraction

`HashtagExtractor.tags(from:)` strips fenced code blocks (` ``` `…` ``` `) and
URLs from the body before regex-matching, so hashtags inside those constructs
are correctly excluded. The regex requires a non-word boundary before the `#`,
so `foo#bar` doesn't match. Slashes are part of the tag character class so
`#nvidia/dgx` captures as a single tag.

The body keeps the hashtags inline — they're duplicated into front matter, not
moved — matching the spec's "Tags remain in the body and are duplicated in
front matter — this is intentional."

## Preferences and configuration

A single window with `NSStackView`s, no nibs, no tabs, no segmented browse pane.
All settings are visible at once, as the spec requires.

User defaults are stored in the standard `com.wesdottoday.stash` plist via
`NSUserDefaults`, scriptable from the command line via `defaults write` —
matching the schema the README documents. The hotkey is stored as two keys
(`hotkeyKeyCode` and `hotkeyModifiers`), where the modifier value is the raw
`NSEvent.ModifierFlags` bitmask. This isn't covered in the README's
`defaults write` documentation, which is the README author's call rather than
something the code should second-guess — the schema is what it is.

The hotkey-capture field temporarily **unregisters the active hotkey** while
the field is first responder, then re-registers with whatever the new (or
unchanged) value is when focus leaves the field. Without this, the user
couldn't rebind to a combination that overlaps with the current one — the
Carbon hotkey would intercept the keypress before the text field ever saw it.

The menu-bar toggle, when set to off, shows a small inline note pointing the
user at the `defaults write …` command to re-enable. The footer carries
`We don't collect any data.` plus a `source` link to the GitHub repo, exactly
as the spec asks.

## Menu bar icon

A small mustache silhouette drawn programmatically with `NSBezierPath` in
`MenuBarController.swift`, marked as a template image so AppKit recolors it
for light/dark menu bars automatically. Generating it in code avoids shipping
an asset catalog, keeps the bundle tiny, and makes the icon's source
inspectable. The icon is static — no animation, no "About," no "Help," no
update checker, per the spec.

## Error handling

The spec gives five error cases, all of which translate into terse
recoverable behaviour rather than dialog boxes:

- **Destination folder missing/unwritable** — `ContentHandler.ensureDirectory`
  returns false; `AppDelegate.handleSubmit` opens the folder picker, accepts
  the new selection into preferences, and retries the save once.
- **Image write fails** — `saveImageAttachment` returns nil; the body gets a
  `> _stash: failed to write image attachment_` placeholder note appended. The
  markdown file (with its front matter) is still written. For bare image drops,
  the result is silently `.error` and the window dismisses.
- **URL fetch fails** — `URLTitleFetcher` returns nil through completion; the
  file is left as-is with `[url](url)`. Silent, no retry.
- **Pasteboard read fails** — `handlePaste` returns false and the text view
  paste path runs normally. An empty/unreadable pasteboard simply means no
  paste happens; the window stays open for typing.
- **File over 100MB** — both at paste time (in the capture view's warning
  banner) and at save time (as the `.fileTooLarge` result), the user is told
  inline and the window stays open.

## What the app does not do

All of the spec's "What This App Does Not Do" items are enforced structurally:

- **No Dock icon** — `LSUIElement=true` in Info.plist plus
  `NSApp.setActivationPolicy(.accessory)`.
- **No background indexing** — nothing in the code reads captures back.
- **No tagging UI** — there is no tagging UI; tags are derived from `#`
  hashtags in the body.
- **No editing/browsing** — the capture view is write-only; there is no list
  view, no detail view, no past-capture access.
- **No syncing** — no network calls beyond the URL title fetch on user
  initiation.
- **No analytics** — no network calls beyond the URL title fetch on user
  initiation. The footer of the preferences pane states this verbatim.
- **No update checker** — no version-comparing network calls of any kind.
- **No notifications** — no `NSUserNotification` / `UNUserNotification` /
  `UserNotifications` imports anywhere; the only feedback path is the in-app
  checkmark indicator.

## Bundle layout

```
stash.app/
├── Contents/
│   ├── Info.plist
│   ├── PkgInfo
│   └── MacOS/
│       └── stash         (the Swift binary)
```

No `Resources/` payload, no embedded frameworks, no helper apps. The binary is
stripped of debug symbols (`strip -x`) and ad-hoc codesigned (`codesign --sign -`)
so Gatekeeper can run it from `/Applications/` after a one-time right-click →
Open. The output bundle size for the local-arch build comes in well under the
5 MB cap.

## What's intentionally not over-built

A few things the codebase deliberately does not have, to stay within the
"requires zero mental energy from the user" intent:

- No telemetry, even local. The app doesn't log to a file. Failures surface as
  silent no-ops or in-window banners, never as crash reports collected on disk.
- No retry logic for the URL title fetch. The spec is explicit ("no retry"),
  and the fetched title is cosmetic anyway — the URL itself is always saved.
- No background queue for the markdown write. The write is a few kilobytes
  through `Data.write(to:options:.atomic)` — synchronous on the main thread is
  fast enough to meet the <100ms Enter-to-file budget, and avoids a context
  switch between submit and the confirmation indicator.
- No window animation. `animationBehavior = .none` on the panel, and the
  confirmation indicator uses an instant `alphaValue` change rather than a
  Core Animation transition. The visual feel is "instant," not "smooth."
- The mustache icon is drawn by hand rather than imported from an SF Symbol or
  asset, which keeps the bundle smaller and avoids depending on a symbol that
  might not exist on macOS 12.
