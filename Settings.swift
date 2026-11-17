import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

// MARK: - Settings

final class RecorderButton: NSButton {
    var mon: Any?
    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded; title = Prefs.shortcutName
        target = self; action = #selector(record)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func record() {
        title = "Press shortcut…"
        hotKey.unregister()
        mon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self else { return e }
            let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if e.keyCode == 53 { self.finish(); return nil }
            let m = carbonMods(f)
            if m == 0 { NSSound.beep(); return nil }
            Prefs.keyCode = UInt32(e.keyCode); Prefs.mods = m
            Prefs.shortcutName = symbols(f) + (e.charactersIgnoringModifiers ?? "?").uppercased()
            self.finish()
            return nil
        }
    }
    func finish() {
        if let m = mon { NSEvent.removeMonitor(m) }
        mon = nil; title = Prefs.shortcutName
        registerHotKeyIfEnabled()
    }
}

final class AppList: NSObject, NSTableViewDataSource {
    let load: () -> [String: String]
    let store: ([String: String]) -> Void
    let table = NSTableView()
    let view = NSStackView()

    init(load: @escaping () -> [String: String], store: @escaping ([String: String]) -> Void) {
        self.load = load; self.store = store
        super.init()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("n")); col.width = 400
        table.addTableColumn(col); table.headerView = nil; table.dataSource = self
        let sc = NSScrollView(); sc.documentView = table; sc.hasVerticalScroller = true; sc.borderType = .bezelBorder
        sc.translatesAutoresizingMaskIntoConstraints = false
        sc.widthAnchor.constraint(equalToConstant: 420).isActive = true
        sc.heightAnchor.constraint(equalToConstant: 88).isActive = true
        let add = NSButton(title: "+", target: self, action: #selector(addApp))
        let rem = NSButton(title: "–", target: self, action: #selector(removeApp))
        view.orientation = .vertical; view.alignment = .leading; view.spacing = 4
        view.setViews([sc, NSStackView(views: [add, rem])], in: .top)
    }

    func numberOfRows(in t: NSTableView) -> Int { load().count }
    func tableView(_ t: NSTableView, objectValueFor c: NSTableColumn?, row: Int) -> Any? {
        let d = load(); return d[d.keys.sorted()[row]]
    }

    @objc func addApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]; p.directoryURL = URL(fileURLWithPath: "/Applications")
        guard p.runModal() == .OK, let u = p.url, let id = Bundle(url: u)?.bundleIdentifier else { return }
        var d = load(); d[id] = u.deletingPathExtension().lastPathComponent
        store(d); table.reloadData()
    }
    @objc func removeApp() {
        var d = load(); let k = d.keys.sorted()
        guard table.selectedRow >= 0, table.selectedRow < k.count else { return }
        d.removeValue(forKey: k[table.selectedRow]); store(d); table.reloadData()
    }
}

final class SettingsController: NSObject, NSWindowDelegate {
    var win: NSWindow?
    var lists: [AppList] = []
    var valueLabel: NSTextField!
    var recorder: RecorderButton!

    func show() {
        if win == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        win?.makeKeyAndOrderFront(nil)
    }

    func caption(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        return l
    }

    func heading(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        return l
    }

    func row(_ title: String, _ control: NSView) -> NSStackView {
        let l = NSTextField(labelWithString: title)
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 100).isActive = true
        let r = NSStackView(views: [l, control])
        r.orientation = .horizontal; r.alignment = .centerY; r.spacing = 8
        return r
    }

    func build() {
        valueLabel = NSTextField(labelWithString: "\(Prefs.limit)")
        let stepper = NSStepper()
        stepper.minValue = 5; stepper.maxValue = 100; stepper.integerValue = Prefs.limit
        stepper.target = self; stepper.action = #selector(stepped(_:))
        let sizeControl = NSStackView(views: [valueLabel, stepper])
        sizeControl.spacing = 6
        recorder = RecorderButton()

        let a = AppList(load: { Prefs.ignored }, store: { Prefs.ignored = $0 })
        let b = AppList(load: { Prefs.hotkeyExcluded }, store: { Prefs.hotkeyExcluded = $0 })
        lists = [a, b]
        let clear = NSButton(title: "Clear history (keeps pinned)", target: self, action: #selector(clearAll))

        let stack = NSStackView(views: [
            row("History size", sizeControl),
            row("Shortcut", recorder),
            heading("Never record copies from"),
            caption("Copies made while these apps are in front are not saved."),
            a.view,
            heading("Shortcut passes through to"),
            caption("In these apps the shortcut keeps its normal meaning (e.g. Ctrl+V in Terminal)."),
            b.view,
            clear
        ])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.setCustomSpacing(16, after: stack.views[1])
        stack.setCustomSpacing(18, after: a.view)
        stack.setCustomSpacing(18, after: b.view)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Clippy Settings"; w.contentView = stack; w.isReleasedWhenClosed = false; w.delegate = self
        let fit = stack.fittingSize
        w.setContentSize(NSSize(width: 420 + 48, height: fit.height))   // list width + left/right insets
        w.center()
        win = w
    }

    @objc func stepped(_ s: NSStepper) {
        Prefs.limit = s.integerValue; valueLabel.stringValue = "\(s.integerValue)"
        Store.shared.prune(); Store.shared.save()
    }
    @objc func clearAll() { Store.shared.clear() }
    func windowWillClose(_ n: Notification) {
        DispatchQueue.main.async { self.win = nil; self.lists = []; self.recorder = nil }
    }
}

let settings = SettingsController()

