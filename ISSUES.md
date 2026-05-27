# stash Issues

## 1. Cmd+A does not select input text

Cmd+A in the capture input field does nothing. Expected: selects all text so the user can delete/replace. The `keyDown(with:)` override in `CaptureTextView` (`CaptureView.swift:394`) intercepts key events before standard key equivalents like Cmd+A can route to `selectAll:`. Needs to pass through events with `.command` modifier (except Enter/Escape) to `super.keyDown(with:)`.

## 2. File paste from clipboard doesn't work

Copying a file in Finder and pasting into the capture window does nothing. `handlePaste()` at `CaptureView.swift:318` uses `readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])` — this may not match how Finder puts file references on the pasteboard. Check whether `NSPasteboard.general.types` actually contains `public.file-url` after a Finder copy. May need to also check for `NSFilenamesPboardType` / `NSPasteboard.PasteboardType("NSFilenamesPboardType")`.

## 3. Image paste from clipboard doesn't work

Copying an image file from Finder fails (same root cause as #2). Copying image content from within an app (e.g., Preview, browser) also fails. `imageDataFromPasteboard()` at `CaptureView.swift:351` checks `.png` and `.tiff` pasteboard types — some apps put image data under different UTIs. May also need to try `NSImage(pasteboard:)` as a fallback, which handles a wider range of pasteboard representations.

## 4. Menu bar icon needs work

The hand-drawn mustache icon (NSBezierPath) doesn't look good at menu bar size. The geometry needs improvement or a different rendering approach — consider an SF Symbol with fallback, or a cleaner bezier path that reads well at 18pt.

## 5. No visual indication of pasted clipboard content

When a file or image is pasted into the capture window, there's no visual feedback that the paste was recognized. The code at `CaptureView.swift:336-340` does set up an image preview and the state exists (`imageVisible`, `imagePreview`), but it's never reached because the paste itself fails (see #2, #3). Once paste is fixed, verify the preview actually displays. A file context indicator (filename label) should also be added for file pastes — currently `pastedFileURL` is set silently with no UI feedback (`CaptureView.swift:326-331`).

## 6. Text + file should save file to attachments/ subfolder

When text is submitted alongside a pasted file, the file should go to `attachments/` — not the root destination folder. The markdown file references the pasted file, creating a dependency. A root-level file with no obvious connection to its markdown note is likely to get deleted during manual Finder cleanup, orphaning the reference. `ContentHandler` should write accompanying files to `attachments/` and reference as `[filename](attachments/filename.ext)`.

## 7. App doesn't appear in Force Quit dialog

`LSUIElement = true` + `.accessory` activation policy hides the app from Force Quit (Cmd+Opt+Esc). With menu bar icon disabled, the user has no way to quit without Terminal. The app must register in Force Quit — `pkill` is not a UX solution.

## 8. Repo link in menu-bar-disabled prompt is not clickable

When the menu bar icon is disabled and the prefs pane shows the prompt to visit the GitHub repo for CLI configuration, the repo URL is plain text — not a hyperlink. Should be a clickable link that opens in the default browser.

## 9. `defaults write` for menuBarEnabled doesn't take effect until relaunch

Running `defaults write com.wesdottoday.stash menuBarEnabled -bool true` after disabling the menu bar icon does not restore the icon live. Relaunch is required. Either observe `NSUserDefaultsDidChangeNotification` for external writes or document the relaunch requirement in the README. (Confirmed: kill + relaunch does pick up the change.)

## 10. Global hotkey capture field in preferences doesn't work

The hotkey input field in the prefs pane doesn't respond to interaction. Clicking on it shows no selected/focused state, and typing a key chord does not update the hotkey. `KeyCaptureField` may not be becoming first responder, or the key event handling isn't wired up properly.

## 11. Save confirmation toggle doesn't persist on re-enable

Unchecking save confirmation works (confirmation stops showing). Re-checking it does not restore the confirmation behavior — the toggle state isn't being saved back to preferences, or the app isn't re-reading the preference on change.

## 12. Confirmation duration: replace text field with slider, range 50–2000ms

The text field for confirmation duration doesn't save or take effect. Replace it with a slider (range 50–2000ms, default 100ms). The slider should live-update the preference immediately — no save button. The current spec range of 50–500ms is too narrow; increase to 2000ms.
