import AppKit
import Carbon.HIToolbox
import ImageIO

// MARK: - Prefs

let defaults = UserDefaults.standard

enum Prefs {
    static var limit: Int {
        get { let v = defaults.integer(forKey: "limit"); return v == 0 ? 20 : min(max(v, 5), 100) }
        set { defaults.set(newValue, forKey: "limit") }
    }
    static var keyCode: UInt32 {
        get { defaults.object(forKey: "keyCode") == nil ? UInt32(kVK_ANSI_V) : UInt32(defaults.integer(forKey: "keyCode")) }
        set { defaults.set(Int(newValue), forKey: "keyCode") }
    }
    static var mods: UInt32 {
        get { defaults.object(forKey: "mods") == nil ? UInt32(controlKey) : UInt32(defaults.integer(forKey: "mods")) }
        set { defaults.set(Int(newValue), forKey: "mods") }
    }
    static var historyEnabled: Bool {
        get { defaults.object(forKey: "historyEnabled") == nil ? true : defaults.bool(forKey: "historyEnabled") }
        set { defaults.set(newValue, forKey: "historyEnabled") }
    }
    static var shortcutName: String {
        get { defaults.string(forKey: "shortcutName") ?? "⌃V" }
        set { defaults.set(newValue, forKey: "shortcutName") }
    }
    // bundle id -> display name
    static var ignored: [String: String] {
        get { defaults.dictionary(forKey: "ignored") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "ignored") }
    }
    static var hotkeyExcluded: [String: String] {
        get { defaults.dictionary(forKey: "hkx") as? [String: String] ?? ["com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm"] }
        set { defaults.set(newValue, forKey: "hkx") }
    }
}

// MARK: - Helpers

func fnv(_ d: Data) -> UInt64 {
    var h: UInt64 = 14695981039346656037
    for b in d { h = (h ^ UInt64(b)) &* 1099511628211 }
    return h
}

func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if f.contains(.command) { m |= UInt32(cmdKey) }
    if f.contains(.shift) { m |= UInt32(shiftKey) }
    if f.contains(.option) { m |= UInt32(optionKey) }
    if f.contains(.control) { m |= UInt32(controlKey) }
    return m
}

func cgFlags(_ m: UInt32) -> CGEventFlags {
    var f: CGEventFlags = []
    if m & UInt32(cmdKey) != 0 { f.insert(.maskCommand) }
    if m & UInt32(shiftKey) != 0 { f.insert(.maskShift) }
    if m & UInt32(optionKey) != 0 { f.insert(.maskAlternate) }
    if m & UInt32(controlKey) != 0 { f.insert(.maskControl) }
    return f
}

func symbols(_ f: NSEvent.ModifierFlags) -> String {
    var s = ""
    if f.contains(.control) { s += "⌃" }
    if f.contains(.option) { s += "⌥" }
    if f.contains(.shift) { s += "⇧" }
    if f.contains(.command) { s += "⌘" }
    return s
}

func sendKey(_ code: CGKeyCode, flags: CGEventFlags) {
    let src = CGEventSource(stateID: .combinedSessionState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
    }
}

func thumb(_ url: URL) -> NSImage? {
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                 kCGImageSourceThumbnailMaxPixelSize: 72,
                                 kCGImageSourceCreateThumbnailWithTransform: true]
    guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(s, 0, opts as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
}

// MARK: - Store (index in RAM is just metadata; payloads live on disk)

struct Item: Codable {
    var id: String
    var kind: String          // "text" | "image" | "file"
    var date: Date
    var pinned: Bool
    var preview: String
    var hash: UInt64
    var paths: [String]?
}

final class Store {
    static let shared = Store()
    let dir: URL
    var items: [Item] = []

    init() {
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Clippy")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
           let i = try? JSONDecoder().decode([Item].self, from: d) { items = i }
    }

    func blob(_ it: Item) -> URL { dir.appendingPathComponent(it.id + (it.kind == "image" ? ".png" : ".txt")) }
    func save() { try? JSONEncoder().encode(items).write(to: dir.appendingPathComponent("index.json"), options: .atomic) }

    func add(_ kind: String, _ preview: String, _ hash: UInt64, data: Data? = nil, paths: [String]? = nil) {
        if let i = items.firstIndex(where: { $0.hash == hash && $0.kind == kind }) {
            var it = items.remove(at: i); it.date = Date(); items.insert(it, at: 0)
        } else {
            let it = Item(id: UUID().uuidString, kind: kind, date: Date(), pinned: false, preview: preview, hash: hash, paths: paths)
            if let d = data { try? d.write(to: blob(it)) }
            items.insert(it, at: 0)
        }
        prune(); save()
    }

    func prune() {
        var n = 0
        var keep: [Item] = []
        for it in items {
            if it.pinned { keep.append(it); continue }
            n += 1
            if n <= Prefs.limit { keep.append(it) } else { try? FileManager.default.removeItem(at: blob(it)) }
        }
        items = keep
    }

    func touch(_ id: String) {
        if let i = items.firstIndex(where: { $0.id == id }) { var it = items.remove(at: i); it.date = Date(); items.insert(it, at: 0); save() }
    }
    func togglePin(_ id: String) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].pinned.toggle(); prune(); save() }
    }
    func remove(_ id: String) {
        if let i = items.firstIndex(where: { $0.id == id }) { try? FileManager.default.removeItem(at: blob(items[i])); items.remove(at: i); save() }
    }
    func clear(keepPinned: Bool = true) {
        for it in items where !(keepPinned && it.pinned) { try? FileManager.default.removeItem(at: blob(it)) }
        items = keepPinned ? items.filter { $0.pinned } : []
        save()
    }
}

// MARK: - Clipboard monitor

final class Monitor {
    var last = NSPasteboard.general.changeCount
    var timer: Timer?

    func start() {
        stop()
        last = NSPasteboard.general.changeCount   // don't capture whatever was copied while history was off
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.25
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func tick() {
        let pb = NSPasteboard.general
        guard pb.changeCount != last else { return }
        last = pb.changeCount
        autoreleasepool { capture(pb) }
    }

    func capture(_ pb: NSPasteboard) {
        let types = pb.types?.map { $0.rawValue } ?? []
        for t in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"] where types.contains(t) { return }
        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, Prefs.ignored[bid] != nil { return }

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let paths = urls.map { $0.path }
            let prev = urls.count == 1 ? urls[0].lastPathComponent : "\(urls[0].lastPathComponent) +\(urls.count - 1) more"
            Store.shared.add("file", prev, fnv(Data(paths.joined(separator: "\n").utf8)), paths: paths)
        } else if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let d = Data(s.utf8)
            guard d.count < 5_000_000 else { return }
            let prev = String(s.prefix(500)).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            Store.shared.add("text", prev, fnv(d), data: d)
        } else {
            var data = pb.data(forType: .png)
            if data == nil, let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
                data = rep.representation(using: .png, properties: [:])
            }
            guard let d = data, d.count < 25_000_000,
                  let src = CGImageSourceCreateWithData(d as CFData, nil),
                  let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return }
            Store.shared.add("image", "Image \(w)×\(h)", fnv(d), data: d)
        }
        panelController.refreshIfOpen()
    }
}

let monitor = Monitor()

// MARK: - Paste

func pasteItem(_ it: Item) {
    let pb = NSPasteboard.general
    pb.clearContents()
    switch it.kind {
    case "text":
        if let s = try? String(contentsOf: Store.shared.blob(it), encoding: .utf8) { pb.setString(s, forType: .string) }
    case "image":
        if let d = try? Data(contentsOf: Store.shared.blob(it)) { pb.setData(d, forType: .png) }
    default:
        pb.writeObjects((it.paths ?? []).map { URL(fileURLWithPath: $0) as NSURL })
    }
    monitor.last = pb.changeCount
    Store.shared.touch(it.id)
    guard AXIsProcessTrusted() else {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        return  // copied to clipboard; paste manually until Accessibility is granted
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { sendKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand) }
}

// MARK: - Global hotkey

final class HotKey {
    var ref: EventHotKeyRef?
    var installed = false
    var onFire: () -> Void = {}

    func register() {
        unregister()
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in hotKey.onFire(); return noErr }, 1, &spec, nil, nil)
            installed = true
        }
        RegisterEventHotKey(Prefs.keyCode, Prefs.mods, EventHotKeyID(signature: OSType(0x434C4950), id: 1), GetApplicationEventTarget(), 0, &ref)
    }
    func unregister() { if let r = ref { UnregisterEventHotKey(r); ref = nil } }
}

let hotKey = HotKey()

// MARK: - Clipboard history on/off (timer + global shortcut stop completely when off)

func registerHotKeyIfEnabled() {
    if Prefs.historyEnabled { hotKey.register() }
}

func applyHistoryEnabled() {
    if Prefs.historyEnabled {
        monitor.start()
        hotKey.register()
    } else {
        monitor.stop()
        hotKey.unregister()
    }
}
