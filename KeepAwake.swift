import AppKit
import IOKit.pwr_mgt
import ServiceManagement

// Everything KeepAwake did, minus its menu: the panel in Panel.swift draws the toggles
// and the status icon is chosen in main.swift. State is always read back from macOS,
// so the checkboxes can never disagree with reality.

final class KeepAwakeController {
    static let prefKey = "keepAwakeEnabled"

    var isAwake = false
    var showsHidden = false
    var showsLibrary = false
    var otherSources: [String] = []
    var onChange: () -> Void = {}          // fired after any change, including the async Finder restart

    private var assertionID: IOPMAssertionID = 0

    // Sleep-preventing assertion types we treat as "keeping the Mac awake".
    private static let awakeTypes: Set<String> = [
        kIOPMAssertionTypePreventUserIdleSystemSleep as String,
        kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
        kIOPMAssertionTypePreventSystemSleep as String,
        "NoIdleSleepAssertion", "NoDisplaySleepAssertion"
    ]
    // Always-on system helpers we don't want to report. Add names here if one shows up as noise.
    private static let ignoredProcesses: Set<String> = ["powerd"]

    private var libraryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
    }
    var startsOnBoot: Bool { SMAppService.mainApp.status == .enabled }

    // MARK: lifecycle

    /// Restore the last Keep Awake choice (the OS drops the assertion when the app quits).
    func restore() {
        if UserDefaults.standard.bool(forKey: Self.prefKey) { start() }
    }

    func shutdown() { stop() }

    // MARK: state

    /// Keep Awake (is our power assertion really active?), hidden files, Library folder.
    func readState() {
        isAwake = assertionIsActive()
        CFPreferencesAppSynchronize("com.apple.finder" as CFString)   // drop any cached Finder prefs
        showsLibrary = !(((try? libraryURL.resourceValues(forKeys: [.isHiddenKey]))?.isHidden) ?? true)

        let raw = CFPreferencesCopyAppValue("AppleShowAllFiles" as CFString, "com.apple.finder" as CFString)
        if let flag = raw as? Bool {
            showsHidden = flag
        } else if let text = raw as? String {      // older guides store it as the string "YES"/"TRUE"
            showsHidden = ["true", "yes", "1"].contains(text.lowercased())
        } else {
            showsHidden = false
        }
    }

    /// Only needed while the panel is open, so it is not part of readState().
    func readOthers() { otherSources = otherAwakeSources() }

    // MARK: actions

    func toggleAwake() {
        if assertionID != 0 { stop() } else { start() }      // decide by what we really hold
        UserDefaults.standard.set(isAwake, forKey: Self.prefKey)
        onChange()
    }

    /// One switch for both: hidden files in Finder AND the ~/Library folder.
    /// Turns both on unless both are already on (then turns both off).
    func toggleHidden() {
        let enable = !(showsHidden && showsLibrary)

        // ~/Library: flip its hidden flag in-process
        var url = libraryURL
        var values = URLResourceValues()
        values.isHidden = !enable
        if (try? url.setResourceValues(values)) != nil { showsLibrary = enable }

        // Hidden files: Finder setting, then restart Finder (skipped if it is already right)
        if showsHidden != enable {
            showsHidden = enable          // optimistic; corrected below from the real system value
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "/usr/bin/defaults write com.apple.finder AppleShowAllFiles -bool \(enable ? "true" : "false") && /usr/bin/killall Finder"]
            task.terminationHandler = { [weak self] _ in
                DispatchQueue.main.async {
                    self?.readState()
                    self?.onChange()
                }
            }
            try? task.run()
        }
        onChange()
    }

    func toggleBoot() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:          try service.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default:                try service.register()
            }
        } catch {
            NSLog("Clippy: login item change failed: \(error)")
        }
        onChange()
    }

    // MARK: who else keeps the Mac awake

    /// Names of OTHER processes that currently hold a sleep-preventing assertion
    /// (e.g. `caffeinate` in Terminal, another keep-awake app, a video call, a download).
    private func otherAwakeSources() -> [String] {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let cf = raw?.takeRetainedValue() else { return [] }
        let table = cf as NSDictionary

        var names = Set<String>()
        for (key, value) in table {
            guard let pid = (key as? NSNumber)?.int32Value, pid != getpid(),
                  let assertions = value as? [[String: Any]] else { continue }
            let holdsAwake = assertions.contains { entry in
                let type = entry[kIOPMAssertionTypeKey as String] as? String ?? ""
                let level = (entry[kIOPMAssertionLevelKey as String] as? NSNumber)?.intValue ?? 0
                return level != 0 && Self.awakeTypes.contains(type)
            }
            if holdsAwake {
                let given = assertions.compactMap { $0["Process Name"] as? String }.first
                names.insert(given ?? processName(for: pid))
            }
        }
        return names.subtracting(Self.ignoredProcesses).sorted()
    }

    /// Human-readable name of a process: app name, else executable name, else asks `ps` (works for
    /// system daemons owned by other users). Never returns a bare PID.
    private func processName(for pid: pid_t) -> String {
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName, !name.isEmpty { return name }

        var buffer = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            let name = String(cString: buffer)
            if !name.isEmpty { return name }
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        if (try? task.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return (path as NSString).lastPathComponent }
        }
        return "unknown process"
    }

    // MARK: power assertion

    /// Asks macOS whether our sleep assertion currently exists (it is gone if released or if we quit).
    private func assertionIsActive() -> Bool {
        guard assertionID != 0 else { return false }
        let props = IOPMAssertionCopyProperties(assertionID)?.takeRetainedValue() as? [String: Any]
        return !(props?.isEmpty ?? true)
    }

    private func start() {
        guard assertionID == 0 else { return }               // already holding one
        // Display-sleep variant: keeps the screen on, and (by definition) the Mac awake too.
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Clippy keep awake" as CFString,
            &assertionID
        )
        if result != kIOReturnSuccess { assertionID = 0 }
        isAwake = (result == kIOReturnSuccess)
    }

    private func stop() {
        if assertionID != 0 { IOPMAssertionRelease(assertionID) }
        assertionID = 0
        isAwake = false
    }
}

let keepAwake = KeepAwakeController()
