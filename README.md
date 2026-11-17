# Clippy

A lightweight clipboard manager for macOS that lives in the menu bar. It remembers the last *N* things you copied — text, files and images — and pastes any of them back with a global shortcut. It also bundles a small "keep my Mac awake" toggle and a few Finder utilities.

Written in **Swift and plain AppKit** — no SwiftUI, no Electron, no third-party dependencies, no Xcode project. The main design goal was to **use as little RAM as possible**.

<!-- Add a screenshot or GIF here, e.g. docs/demo.gif -->
<!-- ![Clippy panel](docs/panel.png) -->

## Features

**Clipboard history**
- Saves text, files and images, with a user-chosen history size (5–100, default 20)
- Global shortcut (default `⌃V`, fully customizable) opens a floating panel next to the cursor
- Pick an item with the mouse, arrow keys + Enter, or `⌘1`–`⌘9`; it is pasted straight into the app you were using
- Search, pinning (pinned items stay on top and don't count toward the limit) and per-item delete (`⌘⌫`)
- History persists across restarts
- Privacy: ignores copies that password managers mark as concealed/transient, and lets you list apps whose copies are never recorded
- Per-app shortcut pass-through, so `Ctrl+V` still works in Terminal/iTerm

**Menu bar panel (click the icon)**
- **Keep Mac Awake** — prevents idle sleep and keeps the display on, and shows which *other* apps are also keeping the Mac awake
- **Show Hidden Files & Library** — one toggle for Finder's hidden files and the `~/Library` folder
- **Start at Login**, **Clipboard History** on/off, Settings and Quit
- The menu bar icon reflects state: grey moon (idle), yellow moon (awake), spaceship (hidden files shown)

## Keyboard shortcuts

| Key | Action |
|---|---|
| `⌃V` (customizable) | Open the history panel |
| `↑` / `↓`, `Enter` | Move / paste the selected item |
| `⌘1` – `⌘9` | Paste the Nth item |
| `⌘P` | Pin / unpin the selected item |
| `⌘⌫` | Delete the selected item |
| `Esc` | Close the panel |
| `⌘Q` | Quit |

## How it keeps RAM low

- **Native AppKit only.** No web view, no SwiftUI runtime, no external libraries.
- **History lives on disk, not in memory.** RAM holds only a small metadata index (id, type, date, short preview, hash). Full text and image data are read back only when you paste.
- **The panel is built when it opens and released when it closes**, so a hidden panel costs nothing.
- **Thumbnails are generated lazily** with ImageIO (`CGImageSourceCreateThumbnailAtIndex`), only for rows that are on screen, and downscaled without decoding the full image.
- **Cheap clipboard watching.** macOS has no clipboard-change notification, so a timer compares `NSPasteboard.changeCount` every 0.5 s (with timer tolerance so wake-ups can be coalesced). Real work only happens when it changes, inside an `autoreleasepool`.
- **Size caps** on what gets stored (text under 5 MB, images under 25 MB) and de-duplication by content hash (FNV-1a).
- **Nothing runs when turned off.** Switching Clipboard History off stops the timer and unregisters the global shortcut. The "who else keeps the Mac awake" lookup only runs while the panel is open.
- **Size-optimized build** (`-Osize`, whole-module optimization, dead-code stripping).

Measured idle memory: _fill in — Activity Monitor → "Memory" column, not "Real Mem"_

## Tech stack

| Area | What it uses |
|---|---|
| Language / UI | Swift 5 mode, AppKit (`NSStatusItem`, `NSPanel`, `NSTableView`, `NSVisualEffectView`) |
| Global hotkey | Carbon `RegisterEventHotKey` (needs no extra permission) |
| Auto-paste | `CGEvent` synthetic `⌘V` (needs the Accessibility permission) |
| Clipboard | `NSPasteboard` polling, `org.nspasteboard.*` markers for concealed/transient data |
| Images | ImageIO thumbnails |
| Keep awake | IOKit power assertions (`IOPMAssertionCreateWithName`, `IOPMCopyAssertionsByProcess`) |
| Start at login | `SMAppService` |
| Persistence | `UserDefaults` for settings; JSON index + payload files in `~/Library/Application Support/Clippy` |
| Build | `swiftc` driven by a shell script — no Xcode project |

## Project structure

```
main.swift        App entry point, status item, icon state, Ctrl+V / icon click routing
Core.swift        Preferences, content-hashed history store, clipboard monitor, paste, global hotkey
KeepAwake.swift   Power assertion, hidden-files/Library toggle, login item, "kept awake by" lookup
Panel.swift       The floating panel (full and history-only variants)
Settings.swift    Settings window: history size, shortcut recorder, ignored apps, pass-through apps
build.sh          Builds and ad-hoc signs Clippy.app, converts the icons
*.png             Menu bar icon sources (idle, active, spaceship)
```

## Build and run

Requirements: macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh
open Clippy.app
```

On first use, macOS will ask for the **Accessibility** permission (System Settings → Privacy & Security → Accessibility). It is needed only for auto-paste. Without it, the chosen item is still placed on the clipboard and you can paste it yourself.

## Design notes and trade-offs

- **Polling instead of notifications.** The pasteboard has no change event, so polling is the standard approach; the 0.5 s interval with tolerance is a balance between latency and wake-ups.
- **`Ctrl+V` vs. terminals.** A global hotkey swallows the key everywhere, which breaks "literal next character" in shells and Vim. Clippy checks the frontmost app: for apps on the pass-through list it briefly unregisters the hotkey, replays the keystroke, and re-registers it.
- **Files are stored as paths, not copies.** This keeps the history small, but an entry stops working if the file is moved or deleted.
- **One panel, two modes.** The shortcut opens a history-only panel for quick pasting; clicking the menu bar icon opens the same panel with the toggles added.
- **Merged from two apps.** This started as two separate menu bar apps (a clipboard history and a keep-awake utility). Merging them means one process, one menu bar slot and one build.

## Known limitations

- Ad-hoc signed, so macOS may ask you to re-grant Accessibility after each rebuild.
- History is stored unencrypted on disk. Concealed items are skipped, but anything else you copy is saved — use the ignored-apps list for sensitive apps.
- The full history index is rewritten on each change, which is fine for 100 items but would not scale to thousands.
- Search covers the first 500 characters of each text item.
- No automated tests yet.

## Possible next steps

- Unit tests for the store and the de-duplication logic
- Encrypt stored history
- Rich-text and multi-format clipboard items
- Proper code signing and notarization for distribution

## License

MIT — add a `LICENSE` file before publishing.
