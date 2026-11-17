import AppKit

// The single panel: KeepAwake toggles on top, clipboard history below.
// It is built when it opens and released when it closes, so it costs nothing while hidden.

final class KeyPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onResign: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() { super.resignKey(); onResign?() }
    override func performKeyEquivalent(with e: NSEvent) -> Bool { onKey?(e) == true || super.performKeyEquivalent(with: e) }
}

final class RowView: NSTableCellView {
    let icon = NSImageView(frame: NSRect(x: 8, y: 4, width: 32, height: 32))
    let label = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")
    let pinBtn = NSButton(frame: NSRect(x: 262, y: 8, width: 24, height: 24))
    var onPin: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 40))
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.frame = NSRect(x: 48, y: 10, width: 210, height: 20)
        label.lineBreakMode = .byTruncatingTail
        pinBtn.isBordered = false
        pinBtn.imagePosition = .imageOnly
        pinBtn.target = self; pinBtn.action = #selector(pinTapped)
        badge.frame = NSRect(x: 292, y: 10, width: 44, height: 20)
        badge.alignment = .right
        badge.textColor = .secondaryLabelColor
        badge.font = .systemFont(ofSize: 11)
        addSubview(icon); addSubview(label); addSubview(pinBtn); addSubview(badge)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func pinTapped() { onPin?() }

    func configure(_ it: Item, index: Int) {
        label.stringValue = it.preview
        badge.stringValue = index < 9 ? "⌘\(index + 1)" : ""
        pinBtn.image = NSImage(systemSymbolName: it.pinned ? "pin.fill" : "pin", accessibilityDescription: it.pinned ? "Unpin" : "Pin")
        pinBtn.contentTintColor = it.pinned ? .controlAccentColor : .tertiaryLabelColor
        pinBtn.toolTip = it.pinned ? "Unpin (⌘P)" : "Pin (⌘P)"
        switch it.kind {
        case "image": icon.image = thumb(Store.shared.blob(it))
        case "file": icon.image = NSWorkspace.shared.icon(forFile: it.paths?.first ?? "")
        default: icon.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil)
        }
    }
}

final class PanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var panel: KeyPanel?
    var table: NSTableView!
    var search: NSSearchField!
    var awakeBtn: NSButton!
    var hiddenBtn: NSButton!
    var bootBtn: NSButton!
    var historyBtn: NSButton!
    var othersLabel: NSTextField!
    var offLabel: NSTextField!
    var rows: [Item] = []
    var lastResignHide = Date.distantPast
    let rowID = NSUserInterfaceItemIdentifier("row")

    /// full = the menu bar icon: KeepAwake toggles + history + Quit.
    /// compact (the Ctrl+V shortcut) = history only.
    func toggle(full: Bool) {
        if panel != nil { hide(); return }
        // Clicking the menu bar icon while the panel is open first makes the panel resign key (which
        // closes it) and only then fires the click. Without this, that click would reopen it at once.
        if Date().timeIntervalSince(lastResignHide) < 0.3 { return }
        show(full: full)
    }

    func refreshIfOpen() { if panel != nil { reload(keepSel: true) } }

    // MARK: building

    func makeToggle(_ title: String, _ action: Selector, row: Int, in v: NSView, h: CGFloat, w: CGFloat) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        b.frame = NSRect(x: 14, y: h - 36 - 26 * CGFloat(row), width: w - 28, height: 24)
        v.addSubview(b)
        return b
    }

    func show(full: Bool) {
        if full {
            keepAwake.readState()
            keepAwake.readOthers()
        }

        let w: CGFloat = 380
        let h: CGFloat = full ? 500 : 380
        let topH: CGFloat = full ? 144 : 0       // KeepAwake section height
        let bottomH: CGFloat = full ? 36 : 0     // Quit bar height

        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .popUpMenu; p.isFloatingPanel = true; p.hasShadow = true
        p.isOpaque = false; p.backgroundColor = .clear; p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.onKey = { [weak self] e in self?.handleKey(e) ?? false }
        p.onResign = { [weak self] in DispatchQueue.main.async { self?.hide(fromResign: true) } }

        let vev = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        vev.material = .popover; vev.state = .active; vev.wantsLayer = true
        vev.layer?.cornerRadius = 10; vev.layer?.masksToBounds = true

        if full {
            // KeepAwake section (top)
            awakeBtn = makeToggle("Keep Mac Awake", #selector(awakeClicked), row: 0, in: vev, h: h, w: w)
            hiddenBtn = makeToggle("Show Hidden Files & Library", #selector(hiddenClicked), row: 1, in: vev, h: h, w: w)
            hiddenBtn.allowsMixedState = true
            bootBtn = makeToggle("Start at Login", #selector(bootClicked), row: 2, in: vev, h: h, w: w)
            historyBtn = makeToggle("Clipboard History", #selector(historyClicked), row: 3, in: vev, h: h, w: w)

            othersLabel = NSTextField(labelWithString: "")
            othersLabel.frame = NSRect(x: 18, y: h - 136, width: w - 36, height: 18)
            othersLabel.font = .systemFont(ofSize: 11)
            othersLabel.textColor = .secondaryLabelColor
            othersLabel.lineBreakMode = .byTruncatingTail
            vev.addSubview(othersLabel)

            let sep = NSBox(frame: NSRect(x: 12, y: h - 144, width: w - 24, height: 1))
            sep.boxType = .separator
            vev.addSubview(sep)

            // Bottom bar: Quit
            let sep2 = NSBox(frame: NSRect(x: 12, y: bottomH - 1, width: w - 24, height: 1))
            sep2.boxType = .separator
            let quit = NSButton(title: "Quit Clippy", target: self, action: #selector(quitClicked))
            quit.isBordered = false
            quit.alignment = .left
            quit.frame = NSRect(x: 14, y: 6, width: 200, height: 24)
            let quitKey = NSTextField(labelWithString: "⌘Q")
            quitKey.frame = NSRect(x: 292, y: 8, width: 44, height: 20)
            quitKey.alignment = .right
            quitKey.font = .systemFont(ofSize: 11)
            quitKey.textColor = .secondaryLabelColor
            vev.addSubview(sep2); vev.addSubview(quit); vev.addSubview(quitKey)
        }

        // Clipboard section
        let searchY = h - topH - 36
        search = NSSearchField(frame: NSRect(x: 10, y: searchY, width: w - 54, height: 28))
        search.placeholderString = "Search…"; search.delegate = self

        let gear = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")!, target: self, action: #selector(openSettings))
        gear.isBordered = false
        gear.frame = NSRect(x: w - 38, y: searchY, width: 28, height: 28)
        gear.toolTip = "Settings"

        table = NSTableView(frame: .zero)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")); col.width = w
        table.addTableColumn(col)
        table.headerView = nil; table.rowHeight = 40; table.backgroundColor = .clear
        table.style = .plain; table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(clicked)

        let listH = h - topH - 44 - bottomH
        let sc = NSScrollView(frame: NSRect(x: 0, y: bottomH, width: w, height: listH))
        sc.documentView = table; sc.hasVerticalScroller = true; sc.autohidesScrollers = true; sc.drawsBackground = false

        offLabel = NSTextField(labelWithString: "Clipboard history is off")
        offLabel.frame = NSRect(x: 0, y: bottomH + listH / 2 - 10, width: w, height: 20)
        offLabel.alignment = .center
        offLabel.textColor = .secondaryLabelColor

        vev.addSubview(search); vev.addSubview(gear); vev.addSubview(sc); vev.addSubview(offLabel)
        p.contentView = vev
        panel = p
        refreshToggles()
        reload(keepSel: false)

        let m = NSEvent.mouseLocation
        let scr = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main!
        let v = scr.visibleFrame
        let x = min(max(m.x - 20, v.minX), v.maxX - w)
        let y = min(max(m.y - h - 10, v.minY), v.maxY - h)
        p.setFrameOrigin(NSPoint(x: x, y: y))
        p.makeKeyAndOrderFront(nil)
        if Prefs.historyEnabled { p.makeFirstResponder(search) }
    }

    func hide(fromResign: Bool = false) {
        guard let p = panel else { return }
        if fromResign { lastResignHide = Date() }
        panel = nil
        p.orderOut(nil); p.contentView = nil
        table = nil; search = nil; rows = []
        awakeBtn = nil; hiddenBtn = nil; bootBtn = nil; historyBtn = nil; othersLabel = nil; offLabel = nil
    }

    // MARK: toggles

    /// Re-reads nothing from the system; just draws what keepAwake / Prefs currently say.
    func refreshToggles() {
        guard panel != nil, awakeBtn != nil else { return }
        awakeBtn.state = keepAwake.isAwake ? .on : .off
        // checkmark = both on, dash = only one of them is on, empty = both off
        hiddenBtn.state = (keepAwake.showsHidden && keepAwake.showsLibrary) ? .on : ((keepAwake.showsHidden || keepAwake.showsLibrary) ? .mixed : .off)
        bootBtn.state = keepAwake.startsOnBoot ? .on : .off
        historyBtn.state = Prefs.historyEnabled ? .on : .off

        let src = keepAwake.otherSources
        if src.isEmpty {
            othersLabel.stringValue = ""
        } else {
            let shown = src.prefix(3).joined(separator: ", ")
            let extra = src.count > 3 ? " +\(src.count - 3) more" : ""
            othersLabel.stringValue = "Also kept awake by: \(shown)\(extra)"
        }
    }

    func keepFocus() { if Prefs.historyEnabled { panel?.makeFirstResponder(search) } }

    @objc func awakeClicked() { keepAwake.toggleAwake(); refreshToggles(); keepFocus() }
    @objc func hiddenClicked() { keepAwake.toggleHidden(); refreshToggles(); keepFocus() }
    @objc func bootClicked() { keepAwake.toggleBoot(); refreshToggles(); keepFocus() }
    @objc func historyClicked() {
        Prefs.historyEnabled.toggle()
        applyHistoryEnabled()
        refreshToggles()
        reload(keepSel: false)
        if Prefs.historyEnabled { panel?.makeFirstResponder(search) } else { panel?.makeFirstResponder(nil) }
    }
    @objc func openSettings() { hide(); settings.show() }
    @objc func quitClicked() { NSApp.terminate(nil) }

    // MARK: history list

    func reload(keepSel: Bool) {
        guard panel != nil else { return }
        let on = Prefs.historyEnabled
        search.isEnabled = on
        offLabel.isHidden = on
        guard on else { rows = []; table.reloadData(); return }

        let q = search.stringValue.lowercased()
        let all = Store.shared.items
        let f = q.isEmpty ? all : all.filter { $0.preview.lowercased().contains(q) }
        rows = f.filter { $0.pinned } + f.filter { !$0.pinned }
        let sel = keepSel ? max(table.selectedRow, 0) : 0
        table.reloadData()
        if !rows.isEmpty { table.selectRowIndexes([min(sel, rows.count - 1)], byExtendingSelection: false) }
    }

    func pick(_ r: Int) {
        guard r >= 0, r < rows.count else { return }
        let it = rows[r]
        hide()
        pasteItem(it)
    }

    @objc func clicked() { pick(table.clickedRow) }

    func move(_ d: Int) {
        guard !rows.isEmpty else { return }
        let r = min(max(table.selectedRow + d, 0), rows.count - 1)
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    func handleKey(_ e: NSEvent) -> Bool {
        guard e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return false }
        if let c = e.charactersIgnoringModifiers {
            if let d = Int(c), d >= 1, d <= 9 { pick(d - 1); return true }
            if c == "q" { NSApp.terminate(nil); return true }
            if c == "p", table.selectedRow >= 0, table.selectedRow < rows.count {
                Store.shared.togglePin(rows[table.selectedRow].id); reload(keepSel: true); return true
            }
        }
        if e.keyCode == 51, table.selectedRow >= 0, table.selectedRow < rows.count {
            Store.shared.remove(rows[table.selectedRow].id); reload(keepSel: true); return true
        }
        return false
    }

    // table
    func numberOfRows(in t: NSTableView) -> Int { rows.count }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let v = (t.makeView(withIdentifier: rowID, owner: self) as? RowView) ?? RowView()
        v.identifier = rowID
        let item = rows[row]
        v.configure(item, index: row)
        v.onPin = { [weak self] in
            DispatchQueue.main.async {
                guard self?.panel != nil else { return }
                Store.shared.togglePin(item.id)
                self?.reload(keepSel: true)
            }
        }
        return v
    }

    // search field
    func controlTextDidChange(_ n: Notification) { reload(keepSel: false) }
    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): pick(table.selectedRow); return true
        case #selector(NSResponder.cancelOperation(_:)): hide(); return true
        default: return false
        }
    }
}

let panelController = PanelController()
