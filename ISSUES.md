# stash Issues

## 1. Cmd+A does not select input text

**Status: Resolved** (commit 9446d0d)

## 2. File paste from clipboard doesn't work

**Status: Resolved** (commit 836179e)

## 3. Image paste from clipboard doesn't work

**Status: Resolved** (commit 836179e)

## 4. Menu bar icon needs work

**Status: Resolved** (commit 327abbf)

## 5. No visual indication of pasted clipboard content

**Status: Resolved** (commits 836179e, dba428f)

## 6. Text + file should save file to attachments/ subfolder

**Status: Resolved** (commit b632231)

## 7. App doesn't appear in Force Quit dialog

**Status: Open**

The app correctly omits `LSUIElement` from Info.plist and sets `NSApp.setActivationPolicy(.accessory)` at launch in `main.swift`. However, when the menu bar icon is disabled, the activation policy is never switched to `.regular` — only `menuBar.uninstall()` is called. With no menu bar icon and no Force Quit entry, the user has no way to quit without Terminal.

### Suggested fix

Switch activation policy when menu bar visibility changes. In both the `defaultsChanged(_:)` handler and the `onMenuBarChanged` callback from preferences:

```swift
if menuBarEnabled {
    self.menuBar.install()
    NSApp.setActivationPolicy(.accessory)
} else {
    self.menuBar.uninstall()
    NSApp.setActivationPolicy(.regular)
}
```

This gives the app a Dock icon and Force Quit entry when the menu bar icon is hidden, and removes them when it's restored. The plist is already correct (no `LSUIElement`), so the runtime policy switch should take effect immediately.

## 8. `defaults write` hints in preferences are not selectable

**Status: Open (partially addressed)**

When the menu bar icon is disabled, the preferences pane shows the `defaults write` command to re-enable it. The repo link was made clickable (commit 4f686ba), but the command text itself (`defaults write com.wesdottoday.stash menuBarEnabled -bool true`) is rendered via `NSTextField(labelWithString:)`, which is non-selectable. The user can't highlight or copy the command.

### Suggested fix

Make `menuBarNoteCode` selectable by setting `isSelectable = true` on the text field. `NSTextField` supports this — it allows click-and-drag selection and Cmd+C without making the field editable:

```swift
menuBarNoteCode.isSelectable = true
```

Optionally, add a small "Copy" button next to the command that puts the string on the pasteboard via `NSPasteboard.general.setString(…, forType: .string)`.

## 9. `defaults write` changes don't take effect until relaunch

**Status: Open**

The app observes `UserDefaults.didChangeNotification` and diffs against a cached snapshot in `defaultsChanged(_:)`. This works for in-process writes but does not reliably detect external `defaults write` CLI commands — the `defaults` tool writes directly to the plist on disk, and `UserDefaults`' in-memory cache may not pick up the change, so the notification never fires.

### Suggested fix

**Option A — Periodic sync poll.** Add a low-frequency timer (every 2–3 seconds) that calls `UserDefaults.standard.synchronize()` to force a re-read from disk. The existing `defaultsChanged(_:)` diff logic then fires naturally. `synchronize()` is deprecated but still functional and is the right tool for detecting external writes.

**Option B — KVO on individual keys.** Replace the `didChangeNotification` observer with KVO observers on each preference key (`destinationFolder`, `menuBarEnabled`, `hotkeyKeyCode`, `hotkeyModifiers`). KVO on `UserDefaults` can detect external changes because the getter re-reads from disk.

**Option C — Watch the plist file.** Use `DispatchSource.makeFileSystemObjectSource` on `~/Library/Preferences/com.wesdottoday.stash.plist`. When the file changes, call `synchronize()` and run the diff.

Option A is simplest and most reliable for a utility app.

## 10. Global hotkey capture field in preferences doesn't work

**Status: Resolved** (commit 782f65c)

## 11. Save confirmation toggle doesn't persist on re-enable

**Status: Resolved**

## 12. Confirmation duration: replace text field with slider, range 50–2000ms

**Status: Resolved** (commit 759aa50)
