# stash-macos — Ecosystem Build Plan (hub + voice)

> Ecosystem context: [`../DESIGN.md`](../DESIGN.md). Authoritative current behavior:
> [`BUILD.md`](BUILD.md) + [`DECISIONS.md`](DECISIONS.md). This plan *extends* a shipped, working
> app; new scope folds into `DECISIONS.md` as it lands. Existing non-negotiables (latency/resource
> budgets, no third-party deps, swiftc+Makefile, single binary) still hold. Plan approved 2026-06-12
> after an adversarial resilience review. Consumes contracts in [`../stash-relay/PLAN.md`].

## Role in the suite

The macOS `stash` app (global hotkey → paste/type → markdown into `_inbox/`) becomes the suite's
**hub / system of record** and gains **voice capture**. It's the only component that can decrypt
captures and write them into the (Drive-mounted) vault `_inbox/`, so it's capture client + relay
consumer + voice recorder in one.

> **The Mac is a laptop, NOT always-on.** It sleeps, closes its lid, roams Wi-Fi/tether/VPN/captive
> portals, and is frequently offline. DESIGN.md (and relay PLAN.md) call it "always-on" — that
> premise is **wrong** and is being corrected; it drives the resilience design below. The relay is
> crash-safe; **the Mac side is where the data-loss paths are**, so that's where this plan is deep.

**Confirmed decisions:** min macOS **bumped to 26** (full `SpeechAnalyzer` parity with iOS; drops
the public app's 13–25 users — accepted); Share extension **deferred to the final milestone**; voice
toast shows **red dot + elapsed timer + a rolling one-line live transcript**.

## ⚠️ Charter expansion (record in DECISIONS.md when built)

`BUILD.md`'s **"No syncing"** + "no network except the URL fetch" non-goals are **deliberately
overturned** by the hub role (persistent SSE + writing files received from another device) — a
deviation on par with the documented Carbon-hotkey one. **The hot path stays sacred** (hotkey→paint
<50ms, Enter→file <100ms, dismiss→focus <16ms); all relay/SSE/voice work runs on background queues,
never on the hotkey→panel-show path. Idle RSS/CPU budgets get a **stated revision** for one held SSE
socket (re-baselined in M6). **No new third-party deps** — `URLSession`, `AVFoundation`, `Speech`,
`CryptoKit`, `Security`(Keychain), `Network`(NWPathMonitor), `CoreImage`(QR) are all system
frameworks; the swiftc+Makefile single target holds until the deferred `.appex`.

## Resilience & correctness — the laptop reality (the load-bearing part)

The consumer is a **serial pipeline** (one item at a time, in `seq` order, on a dedicated background
queue) — at ~2 devices, throughput is a non-issue and serial ordering removes whole classes of race.

**1. SSE connection lifecycle (intermittent connectivity).**
- A **`.default` `URLSession` with a custom data-task delegate** processing bytes incrementally —
  **NOT** a `.background` session (those are for discrete transfers, can't hold an indefinite
  stream). Do **not** copy the `URLTitleFetcher` config — its short timeouts would kill the stream.
- `timeoutIntervalForResource` ≈ effectively infinite (else the stream dies at the 7-day default);
  `timeoutIntervalForRequest` > ping interval; **`waitsForConnectivity = false`** — `NWPathMonitor`
  is the single owner of reconnect decisions.
- **Ping-watchdog ~45–50s** (relay pings every 20s); reset on **any** received byte. Use a
  `DispatchSourceTimer` (App-Nap-resilient), not `Timer`.
- **`NSWorkspace.didWakeNotification`** (already observed for hotkey re-reg) → **cancel the existing
  task first** (it's half-open after sleep; the watchdog won't notice the wall-clock gap), then
  reconnect. **`NWPathMonitor`** → reconnect on path-satisfied, **debounced ~1–2s** (roaming flaps);
  a satisfied path ≠ relay reachable (captive portals), so an immediate failure is a normal backoff
  step.
- Backoff: exponential + **full jitter**, cap ~30–60s; reset on wake/path-up, not on immediate-fail.

**2. No-loss delivery: write-cursor + poison set + durable ack queue + id-idempotency.**
Hazard: if the persisted cursor advances on *notification receipt*, an item the Mac never durably
wrote is **lost** (the relay replays only `seq > cursor` and never re-notifies a sent item). Rules:
- **Canonical per-item order:** `fetch → decrypt → write atomically + fsync → record item-id written
  (app-local set) → advance contiguous cursor → enqueue durable ack`. **Never ack before the file is
  durably written.**
- **Cursor = contiguous high-water mark of items actually WRITTEN**, persisted in app-support (not
  "items notified"); sent as `Last-Event-ID` on reconnect.
- **Poison set:** persisted `seq > cursor` that are *terminally* failed (see #3) and skipped, so a
  poison item doesn't block the cursor forever (which would re-replay the whole backlog each
  reconnect). Cursor advances past a `seq` only when it's written **or** poisoned.
- **Idempotency keyed on item id**, checked against an **app-local written-id set** — **NOT** by
  probing `_inbox/` (a Drive/File-Provider mount: eventually-consistent, dataless placeholders — an
  unreliable oracle, see #7). Re-delivery is then a safe no-op. **Idempotency is load-bearing.**
- **Durable, on-disk ack queue**, independent of the cursor: a failed ack POST leaves the item
  written but unacked, and the cursor is already past it (never re-notified) → without a durable
  queue it leaks in the relay until TTL on every crash. Replay on launch/wake. **Pace acks** (small
  concurrency cap, honor `429`/`Retry-After`) so a post-vacation drain doesn't trip the relay rate
  limit and amplify via retries.

**3. Poison vs transient vs not-yet-keyed.**
- **Transient** (network/5xx/timeout) → retry with backoff; don't advance cursor.
- **Terminal/poison** (GCM auth failure, AAD mismatch, malformed container) → **do not ack** (acking
  lets the relay purge the evidence), add to poison set, **surface to user**, let TTL purge.
- **Not-yet-keyed** (API key present, SSE connects, but **no E2E key** in Keychain) → **pause
  consumption; do NOT poison** (else the whole backlog is discarded as undecryptable).
- **Voice is all-or-nothing:** both framed parts (audio `0x01`, vtt `0x02`) must decrypt before
  *either* is written; else poison the whole item (a lone file breaks the shared-`base` pairing).

**4. Keychain accessibility (the laptop spends most "awake" time locked).** Daemon-read secrets
(device API key, E2E key) use **`kSecAttrAccessibleAfterFirstUnlock`** — else the consumer can't
read them while locked, and a `didWake`-while-locked reconnect misreads "can't read key" as
auth/poison. Treat **"key temporarily unreadable" (pre-first-unlock/locked)** as retry-later,
distinct from "no key" (#3) and "decrypt failed."

**5. App Nap / energy.** One long-lived `ProcessInfo.beginActivity(options: .userInitiated, reason:)`
held launch→terminate to keep SSE handling alive when unattended. **Explicitly NOT**
`.idleSystemSleepDisabled` / `.latencyCritical` — the laptop must still sleep on lid-close (battery).
It complements (doesn't replace) the `didWake` reconnect: sleep still drops the socket.

**6. Voice across sleep / device changes.**
- Working `.caf` + cues sidecar written **incrementally to disk** (port iOS) — a crash/sleep loses
  only the tail.
- **`NSWorkspace.willSleepNotification`** → **force-flush working files + mark needs-finalize** (the
  pre-suspend window is too short for a full remux); **launch crash-recovery** (port iOS
  `RecordingStore.recoverOrphans`) finishes it.
- Auto-stop on input loss needs **both** a Core-Audio default-input-device listener
  (`kAudioHardwarePropertyDefaultInputDevice`) **and** an **`AVAudioEngineConfigurationChange`**
  observer (re-fetch `inputNode.inputFormat`, reinstall the tap, or the engine throws/garbles on a
  sample-rate/route change). Clamshell-awake is not automatically audio-safe. Gate on **mic TCC**
  (`AVCaptureDevice.authorizationStatus(.audio)`) with a visible state (an `.accessory` app has no
  window to anchor the prompt).

**7. The vault is a Drive/CloudStorage mount.** `write(atomically:)` and `fileExists` are
eventually-consistent there. Keep the written-id/idempotency set **app-local**, never inferred from
folder contents; don't port iOS's "list the destination" collision check against the Drive folder.

**8. Hub-availability ⇄ zero-knowledge trade (inherent).** The Mac is the sole decryptor+writer, so
**agent-action latency is bounded by laptop availability** — captures pile in the relay until drain.
Under zero-knowledge there's no clean fix. Posture: **(a)** accept; **(b)** raise the relay TTL to
cover vacations (weeks) since purge-on-TTL-regardless-of-ack would otherwise **silently delete
un-drained captures**; **(c)** surface "N items waiting / last-drain age." (A second always-on
decrypting custodian is off the table — it moves the E2E key onto the relay host, breaking
zero-knowledge.)

## Grounding in current code (reused vs added)

- **Daemon pattern reused** — `AppDelegate.applicationDidFinishLaunching` pre-allocates held
  singletons (`CaptureWindow`, `HotkeyManager`, `MenuBarController`); the voice toast + SSE client
  join as more pre-allocated singletons. It already observes `NSWorkspace` sleep/wake (reuse for
  SSE) and polls UserDefaults every 2s.
- **`HotkeyManager`** — add a second `EventHotKeyID` (`id:2`) + `onVoiceHotkey` + a `switch` on id.
- **`CaptureWindow`** — its `.nonactivatingPanel` recipe is the template for the voice toast (a
  separate independent `NSPanel`).
- **`MenuBarController`** — add a recording-state icon + `updateIcon(isRecording:)` (image swap, free).
- **`ContentHandler` / `FrontMatter` — NOT reused verbatim (correction).** They stamp `created` and
  the filename from `Date()`/`TimeZone.current` at write time; for relayed items that's wrong
  (#2/#3) — thread a **capture-timestamp + original-UTC-offset** parameter through
  `ContentHandler.save` / `FrontMatter.build` / `Naming`, and make the same-second collision tiebreak
  **deterministic from the item id**. `ContentHash`/`HashtagExtractor` are reused as-is.
- **`Preferences`/`PreferencesWindow`** — add relay URL + device/connection status + "Link a device"
  + the "N waiting / last drain" surface; secrets in **Keychain**, the cursor + written-id set + ack
  queue + poison set in app-support.
- **`URLTitleFetcher`** — pattern reference only; **its config is NOT copied** for SSE (#1).
- **Voice pipeline = port iOS `App/Audio/*`, `App/Transcription/*`, `Naming`, `AudioFinalizer`** for
  byte-compatible output, replacing the iOS-isms (no `AVAudioSession`; drive `AVAudioEngine` input
  node directly; Core-Audio + ConfigurationChange listeners; toast+menu-bar state, not a Live
  Activity).

## Workstreams & milestones

Voice (M1) is standalone/unblocked; relay-side milestones gate on the noted relay milestone.

- **M1 — Voice mode (standalone).** Second non-focus-stealing `NSPanel` toast (red dot + timer +
  rolling live transcript), second global chord, menu-bar recording icon, **Stop saves / Escape
  discards.** `AVAudioEngine`-tap → ALAC writer + `SpeechAnalyzer` → VTT, two files into `_inbox/`
  (no front matter). **Resilience #6.** *(Bumps Makefile/Info.plist min to macOS 26.)*
- **M2 — Enrollment client** *(relay M1).* Register `stash://`; parse
  `stash://enroll?relay=&token=[&k=]`; POST `/enroll/claim` → store `device_id`+`api_key` in Keychain
  (**`AfterFirstUnlock`**, #4). E2E key: store `k` if present, else (Mac = device #1) generate 32
  bytes (`SecRandomCopyBytes`) → Keychain. **"Link a device"** → POST `/enroll/create` → render a QR
  (`CIQRCodeGenerator`) of `stash://enroll?...&k=<e2e>` for iOS.
- **M3 — Relay consumer, text/url** *(relay M2 + macOS M2).* `.default`-session SSE client +
  reconnect/watchdog (#1); the serial **fetch→decrypt→write→record→advance→ack** pipeline with
  cursor/poison/durable-ack/id-idempotency (#2/#3); key-presence + locked-Keychain gating (#3/#4);
  decrypt (CryptoKit `AES.GCM.open`, AAD = item id) → write via `ContentHandler` with the **payload
  capture-timestamp+offset**. App-Nap `beginActivity` (#5).
- **M4 — Relay consumer, voice** *(relay M4).* `type=voice` → fetch container → **all-or-nothing**
  decrypt of both parts (#3) → write the two raw files (payload timestamp) → ack.
- **M5 — Mac → relay producer + self-loop guard** *(relay M1).* After a local capture writes to
  `_inbox/`, also encrypt + `POST /items` (client UUID, capture-timestamp in payload, `X-Stash-Item-*`
  headers). **Self-originated items** returning over SSE are **skipped-for-write but still
  cursor-advanced and acked** (else permanent cursor holes / relay leak).
- **M6 — Share extension (deferred) + budget re-verification.** Hand-roll the `.appex` in the
  Makefile. Re-measure idle RSS/CPU with the SSE socket held; confirm hot-path budgets; write the
  revised idle budget into `DECISIONS.md`.

## Contract changes to propagate (cross-repo)

1. **E2E payload gains a capture timestamp + original UTC offset** (inside the encrypted blob) →
   update the envelope/payload contract in `../stash-relay/PLAN.md` and the producer side in
   `../stash-ios/PLAN.md`. Consumers write `created`/filename from this, never from receipt/drain
   time; same-second collision tiebreak becomes deterministic from the item id.
2. **Correct the "always-on Mac" premise** in `../DESIGN.md` and `../stash-relay/PLAN.md`.
3. **Relay TTL re-spec:** raise the default to cover weeks-long absence; make purge-of-**un-acked**
   items on TTL-expiry a surfaced/configurable event, not a silent delete (vacation data-loss). Add
   a "waiting items / last-drain age" notion the hub can read.

## Build/tooling

Bump `Makefile` `…-macos13.0` → `…-macos26.0` and `Info.plist` `LSMinimumSystemVersion` → `26.0`.
New groups `Sources/Voice/`, `Sources/Relay/`, `Sources/Enroll/` + a small `Keychain.swift` and a
`SyncStore.swift` (cursor / written-id set / poison set / ack queue in app-support). No new external
deps. Single swiftc target through M5; `.appex` adds a second compile+bundle step at M6.

## Verification

- **M1 voice:** chord → toast (dot/timer/live line) → Stop → two correctly-named files (diff vs an
  iOS capture for byte-parity); change/remove default input mid-record **and** plug in a
  different-sample-rate interface → auto-stop+finalize, no garble; **sleep mid-record** → working
  files flushed, finalized on next launch; kill mid-record → recovered; Escape discards (no files);
  mic denied → visible failure state.
- **M2 enrollment:** `stash-relay enroll mac` → click `stash://` → claim, keys in Keychain (readable
  while locked); Mac-as-#1 generates+stores E2E key; "Link a device" renders a scannable QR.
- **M3/M4 hub (resilience is the point):** push items via a test client/curl → Mac writes correct
  markdown/voice-pair, acks (relay purges). **Sleep, push 3, wake** → backlog drains, all 3 land
  **with original capture timestamps** (not wake time), no dups. **Crash between write and ack** →
  on relaunch no duplicate write + ack replays from the durable queue. **Corrupt/wrong-key blob** →
  poisoned (skipped, surfaced, not acked), cursor still progresses. **No E2E key** → consumer pauses
  (backlog not discarded). **Locked screen + wake** → reconnect reads `AfterFirstUnlock` keys.
- **M5 producer:** a local Mac capture appears on another enrolled client; the Mac does **not**
  re-ingest its own item, **and** its cursor advances past it.
- **Budget (M6):** idle RSS/CPU with the SSE socket held; hotkey→paint still <50ms.

## Out of scope / deferred

iOS-side enrollment/`RelayDestination`/outbox/text+share capture live in `stash-ios/PLAN.md`. TLS is
the reverse proxy's job. The macOS app stays a single menu-bar daemon (not split into hub/capture
processes).
