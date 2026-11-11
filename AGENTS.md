# MXCtl: agent guide

Personal macOS menu bar app that replaces **Logi Options+** and **Mos** for the owner's
MX Keys Mini (keyboard, BLE, product 0xB369) and MX Master 3S (mouse, BLE, product 0xB034).
Options+ took ~360 MB RAM and ~3.5 GB disk with telemetry; MXCtl takes ~12–20 MB idle.

## What it does (defaults = the owner's Options+ setup)

- F8 (CID 0x010A) → ⌘⇧4, which MeetRec's screenshot tool listens to (not the system screenshot).
- F9 (0x011C) → mic mute: the mute flag of the default input device (MeetRec reads that flag).
  While muted, `MicIndicator.swift` keeps a red tab with a crossed mic on the right edge of every
  screen, a third down, at screen-saver level (as Options+ showed it; checked against the
  2026-10-19 meeting recording). It follows the device, not the key (Control Center mutes too).
- Battery: in the panel (bolt while charging), read on connect and every 10 min; macOS
  notifications at 15 % and 5 % (once per discharge, not while charging, thresholds in Общие) with
  a battery picture (`scripts/make-battery.swift` → `MXCtl/Resources`). Notifications need the
  `willPresent` delegate, or macOS hides them while MXCtl is in front.
- Thumb gesture button (0x00C3): click → Mission Control; while held, mouse movement (raw XY, the
  pointer stays still) → one swipe per press: left/right = desktops like a trackpad (drag right →
  the desktop on the left, ⌃←; drag left → ⌃→), up = Mission Control,
  down = App Exposé. Sideways wins unless clearly vertical (pressing the button jolts the mouse).
  The first raw XY report after the press is skipped (it is movement from before the press and
  used to pick the wrong swipe half the time); threshold 100. Each press is one short `[gesture]`
  line at release; a swipe that disagrees with the whole movement is a WARN with every report
  (`+ms:dx,dy`), the decision and the pointer, to debug wrong swipes.
- SmartShift threshold written on every connect (first value read from the mouse: 10).
- Mouse wheel: Mos's smoothing and reversal of the wheel only. Defaults are the owner's tuning:
  step 65, speed 1.8, duration 2.75 (Mos had step 50, speed 1.07).
- Mac keyboard (Кнопки → "Клавиатура Mac", one more device next to the Logitech ones; `KeyRemap.swift`): keys MXCtl cannot reach over HID++
  (the MacBook's own keyboard, any other keyboard) are taken over by their key events: "Добавить
  клавишу" records the next key (also media keys and the top row: F5 dictation is key code 176,
  F4 Spotlight 177, F6 Do Not Disturb 178, F3 Mission Control 160), then any action. Session event
  tap on its own thread, only while a key is taken over or recorded; the press, its repeats and
  release are swallowed. Config `macKeys`. MXCtl's own posted events carry `eventMarker`.
- A button set to a key ("Клавиша или сочетание", also a lone modifier such as right ⌃, recorded by
  pressing and releasing it) holds that key while the button is held (hold-to-talk dictation in
  Genius Typer); a lone modifier is posted as flagsChanged with its device bit (0x2000 = right ⌃).
  Buttons with swipes still press the key once on release.
- Everything else stays native ("Как задумано устройством"): volume, backlight, F10 play/pause, back.

Settings → Кнопки looks like Logi Options+: the device picture with a dot on every button (white =
the device's own, coloured = MXCtl action); a click opens that button's action, the thumb wheel dot
leads to Прокрутка. The pictures are own pencil drawings (2026-11-03, replacing Logitech's photos
so the repo can be published): `scripts/make-device-art.py` draws them as SVG, renders them with
rsvg-convert into `MXCtl/Resources/Devices/<model>.png` and `-dark.png` (light ink) and cuts them
to a 64-colour palette with Pillow. The shapes follow the real devices' proportions; the mouse's
wheel and button seam are simplified to one straight line along the body. Dot positions are in
the drawings' pixels, in `DeviceArt.markers`.
Every key/button that can be taken over is also listed (folded, "Все кнопки списком") with an action menu:
key combination, macOS function, media key, open app, URL (own apps' schemes, `shortcuts://`),
Shortcuts command, shell command. "Определить клавишу" diverts everything until a press and
names it. Config: `~/Library/Application Support/MXCtl/config.json` (hand-editable, "Перечитать").

## Battery and journal

`EventJournal.swift` keeps `~/Library/Application Support/MXCtl/events.jsonl` (a year): Mac
sleep/wake, screens sleep/wake, lock/unlock, device connect/disconnect, battery readings (only
changes; the devices also announce changes themselves over UNIFIED_BATTERY 0x1004), and any other
message a device sends by itself (named by feature). Settings → Батарея: charge, last full charge,
drain per day, step graph (drawn by AppKit into an image, not Swift Charts: see PROFILING.md),
notification thresholds, the latest events. In memory: battery readings of the year and other
events of the last 2 days only; the file is mapped and read in the background, unneeded lines are
skipped by kind and time without decoding.
Keyboard backlight (BACKLIGHT2 0x1982, `BacklightConfig` in HIDPP.swift):
read on connect, at wake and every 10 min, changes go to the journal. The keyboard does not report
when the LEDs light up (proximity sensor, light sensor in automatic mode), only its settings.
"Выключать подсветку, когда Mac засыпает или гаснет экран" (default on): off at screens sleep /
system sleep, back on at wake or when the keyboard reconnects; the devices switched off are kept
in UserDefaults (`backlightOffForSleep`) so MXCtl never leaves a backlight off. `--backlight-test`
switches it off for 4 s and back. Feature lists of both devices are in the log ("all features").

## How it works

- `HIDPP.swift`: HID++ 2.0 packets (pure, tested). Over Bluetooth the HID++ reports (long 0x11,
  device index 0xFF) go through the device's normal HID interface (mouse 1/2, keyboard 1/6).
- `LogiDevice.swift`: one device: ping, features (0x1B04 REPROG_CONTROLS_V4, 0x2110/0x2111
  SmartShift, 0x1004 battery), control list, divert/undivert, events. One request at a time.
  Virtual controls (0x00D7) are hidden.
- `DeviceManager.swift`: IOHIDManager on vendor 0x046D, sets devices up on connect and after wake
  (devices forget diversions), turns presses/swipes into actions, follows the config.
- `SmoothScroll.swift`: event tap on its own thread, frames from a CVDisplayLink on the screen under
  the pointer (75 Hz monitor vs 120 Hz MacBook judder otherwise). Posted frames set only the point
  delta and "continuous": writing the line/fixed fields after it zeroes the point delta.
- `ActionRunner.swift`: Mission Control / App Exposé / desktop via `CoreDockSendNotification`
  (launching Mission Control.app from another process gets killed, exit 9).
- Permissions: Input Monitoring (HID++) and Accessibility (scroll tap, posting keys).

## Performance checks

- `open ~/Applications/MXCtl.app --args --settings-scroll-test [battery]`: scrolls the unfolded
  button list (or the battery page) 10 s, logs `Scroll test: … longest … ms, … over 25 ms`
  (buttons: 9.6 ms / 0; was 115 ms / 14 before the TabView removal).
- `--stress-test`: 3 rounds of the settings window on all 6 pages and the panel ×10; logs each
  page's opening time and memory and the memory after each round (38–40 MB, flat).
- `--panel-test`: opens the menu bar panel 6 times, logs the longest main-thread stall
  (first ~90 ms, then ~20 ms).
- Log: ≤ ~512 KB (256 KB + `mxctl.1.log`); debug lines reach the file only when verbose
  (`defaults write com.dmemruk.MXCtl verboseLog -bool true` + restart, or any `--…-test` argument).
- Wheel (verbose): each scroll logs `Scroll settled: frames, avg/longest interval`.
- Deeper: `xcrun xctrace record --template 'Time Profiler' --attach $(pgrep -x MXCtl)`.
  SwiftUI lessons: no `TabView` around long lists (measures the whole page each frame),
  `NSHostingController.sizingOptions` off for the settings window, `Menu` instead of `Picker`.
  macOS 26: the system switch (`Toggle` in a `Form`) and any drawn Swift Charts chart or `Canvas`
  take ~100 MB of graphics memory for a moment when they appear: settings use `LightSwitchStyle`,
  the battery graph is an AppKit-drawn `NSImage`.
- Full audits with before/after tables and how to repeat them: `PROFILING.md`.

## Measured (2026-10-19, `scripts/profile.py`, same load for each)

| | Memory | CPU idle | CPU active (wheel, mouse, gestures) | Disk |
|---|---|---|---|---|
| Logi Options+ & Mos | ~342 MB (agent 96–114, plugin service 149–188, Mos 12, …) | 2.2 % | 10.6 % | ~3.5 GB |
| MXCtl before optimizing | 22 MB idle; 132 MB with the panel open | 0.00 % | 1.84 % | 3.8 MB |
| MXCtl after | 25 MB idle; 27 MB with the panel open | 0.02 % | 1.67 % | 3.8 MB |

Options+'s updater alone wakes the CPU ~40–80 times a second (MXCtl: ~0). No leaks in MXCtl:
`--stress-test` rounds plateau; `leaks` finds only ~14 KB of AppKit internals.
Second audit (2026-10-20, 0.1.16, after the Buttons/Battery pages, journal, backlight): idle 25 MB,
0.02 %; settings peak 147 → 45 MB; a year of journal 36 → 26 MB idle (PROFILING.md).
Tools: `PROFILE=1 scripts/install.sh` signs with get-task-allow so `leaks`/`heap` can attach.

## Logi Options+ and Mos

They grab the same keys and wheel; the panel warns when they run. Options+ is a LaunchAgent
(`/Library/LaunchAgents/com.logi.optionsplus.plist`, label `com.logi.cp-dev-mgr`); stopped for a
session with `launchctl bootout gui/$(id -u)/com.logi.cp-dev-mgr`, back with
`launchctl bootstrap gui/$(id -u) /Library/LaunchAgents/com.logi.optionsplus.plist`. Removal:
`scripts/remove-logi-options-plus.sh` (dry run; `--yes` to do it, needs the admin password;
`--with-rightsight` also removes the webcam software). It moves ~3.5 GB into one Trash folder.
Mos was removed from the login items on 2026-10-19; Options+ was removed the same day (App Cleaner, then this script for the ~2.6 GB it left).

The settings window is forced to the front (`activate(ignoringOtherApps:)` + `orderFrontRegardless`):
a menu bar app's plain `activate()` may be refused and the window opened behind other apps.

Interface languages: Russian and English. Strings are written in Russian in the code (SwiftUI
literals, `String(localized:)`); `MXCtl/Resources/en.lproj/Localizable.strings` translates them
(Russian keys). English is the development region, so any system language other than Russian gets
English. Общие → Язык (`Language.swift`) writes the app's own `AppleLanguages` (none = system) and
restarts MXCtl. After changing any user-visible string, build and run `scripts/check-strings.py`:
it compares the compiler's list of localizable strings (`.stringsdata`) with en.lproj and finds
Russian literals that are not localizable (mark intended ones, like IDs, with `// no-l10n`).

Build and install: `scripts/install.sh`. Tests: `scripts/test.sh`. Icon: `scripts/make-icon.swift`.
Log: `~/Library/Logs/MXCtl/mxctl.log`. Versions: pre-commit hook as in MonitorCtl
(`git config core.hooksPath scripts/git-hooks`).

## Publishing (GitHub, public since 2026-11-03, MIT)

github.com/ProteinR/MXCtl, an ordinary repository: commit on `main` and `git push`. Its history
starts at the public release (0.1.22); the older local history, whose early commits held
Logitech's device pictures, is kept outside the repo in `../MXCtl-history-2026-11-03.bundle`
(never push it). Bug reports come by e-mail (`BugReport.swift`, contact@memruk.dev). With Mail as the default
mail app: a new e-mail with the logs attached (system "compose e-mail" share). Otherwise a window
shows the report (template, versions, devices, last 300 log lines) as selectable text with
"Скопировать": a browser as the default mail app (web Outlook) lost the attachments silently.
`--bug-report` opens the window.
