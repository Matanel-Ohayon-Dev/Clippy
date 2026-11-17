import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var status: NSStatusItem!
    var inactiveIcon: NSImage?
    var activeIcon: NSImage?
    var spaceIcon: NSImage?

    func applicationDidFinishLaunching(_ n: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.target = self
        status.button?.action = #selector(clickStatus)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Icons are loaded once and cached (three 36px PNGs).
        inactiveIcon = loadIcon(named: "icon")
        activeIcon = loadIcon(named: "icon_active")
        spaceIcon = loadIcon(named: "icon_space")

        keepAwake.onChange = { [weak self] in
            self?.updateIcon()
            panelController.refreshToggles()
        }
        keepAwake.readState()
        keepAwake.restore()
        updateIcon()

        hotKey.onFire = {
            if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Prefs.hotkeyExcluded[bid] != nil {
                // let the app have its own key: unregister, replay the keystroke, re-register
                hotKey.unregister()
                sendKey(CGKeyCode(Prefs.keyCode), flags: cgFlags(Prefs.mods))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { registerHotKeyIfEnabled() }
                return
            }
            panelController.toggle(full: false)    // Ctrl+V: history only
        }
        applyHistoryEnabled()      // starts the clipboard timer + shortcut, unless history is switched off
    }

    func applicationWillTerminate(_ n: Notification) { keepAwake.shutdown() }

    func loadIcon(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)   // PNG is 36px -> sharp at 2x
        return image
    }

    /// Icon priority: spaceship (hidden files / Library shown) > yellow moon (awake) > grey moon.
    func updateIcon() {
        let spaceMode = keepAwake.showsHidden || keepAwake.showsLibrary
        guard let button = status?.button else { return }
        if inactiveIcon == nil {
            button.image = nil
            button.title = spaceMode ? "🚀" : (keepAwake.isAwake ? "☀︎" : "☾")      // fallback if the PNGs are missing
        } else {
            button.title = ""
            button.image = (spaceMode ? spaceIcon : nil) ?? (keepAwake.isAwake ? activeIcon : inactiveIcon)
        }
    }

    @objc func clickStatus() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let m = NSMenu()
            m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
            m.addItem(withTitle: "Clear history", action: #selector(clearHistory), keyEquivalent: "").target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
            status.menu = m
            status.button?.performClick(nil)
            status.menu = nil
        } else {
            panelController.toggle(full: true)     // icon click: KeepAwake toggles + history
        }
    }
    @objc func openSettings() { settings.show() }
    @objc func clearHistory() { Store.shared.clear() }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
