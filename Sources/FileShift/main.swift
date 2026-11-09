import AppKit
import FileShiftCore

/// Menu bar front-end. No windows; all logic lives in FileShiftCore.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var service: FileShiftService!
    private var status: FileShiftService.Status = .stopped
    private let defaults = UserDefaults.standard
    private var logPath = ""
    private var instanceLock: InstanceLock?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let env = ProcessInfo.processInfo.environment
        let downloads = env["FILESHIFT_DIRECTORY"]
            ?? fm.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? (home as NSString).appendingPathComponent("Downloads")
        let support = (home as NSString).appendingPathComponent("Library/Application Support/FileShift")
        logPath = (home as NSString).appendingPathComponent("Library/Logs/FileShift/fileshift.log")

        guard let lock = InstanceLock(path: (support as NSString).appendingPathComponent("instance.lock")) else {
            // Another copy is already running (e.g. installed via both Homebrew and install.sh).
            // Exit 0 so launchd's KeepAlive(SuccessfulExit=false) does not keep relaunching us.
            NSLog("FileShift: another instance is already running; exiting.")
            exit(0)
        }
        instanceLock = lock

        let config = FileShiftService.Configuration(
            directory: downloads,
            journalDirectory: (support as NSString).appendingPathComponent("journal"),
            logFile: logPath)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()

        do {
            service = try FileShiftService(config: config)
        } catch {
            NSLog("FileShift: cannot create journal directory: \(error)")
            status = .attention("Cannot create \(support)")
            updateIcon()
            return
        }
        service.onStatusChange = { [weak self] s in
            DispatchQueue.main.async {
                self?.status = s
                self?.updateIcon()
            }
        }
        service.start(paused: defaults.bool(forKey: "paused"))
    }

    func applicationWillTerminate(_ notification: Notification) {
        service?.stop()
    }

    private func updateIcon() {
        let symbol: String
        let tip: String
        switch status {
        case .active: symbol = "arrow.triangle.2.circlepath"; tip = "FileShift: monitoring Downloads"
        case .paused: symbol = "pause.circle"; tip = "FileShift: paused"
        case .stopped: symbol = "arrow.triangle.2.circlepath"; tip = "FileShift: starting"
        case .needsAccess(let m): symbol = "lock.trianglebadge.exclamationmark"; tip = m
        case .attention(let m): symbol = "exclamationmark.triangle"; tip = m
        }
        if let button = statusItem?.button {
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            img?.isTemplate = true
            button.image = img
            button.toolTip = tip
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let statusText: String
        switch status {
        case .active: statusText = "Monitoring Downloads"
        case .paused: statusText = "Paused"
        case .stopped: statusText = "Starting…"
        case .needsAccess(let m): statusText = m
        case .attention(let m): statusText = m
        }
        let header = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if case .needsAccess = status {
            menu.addItem(item("Grant Downloads Access…", #selector(openPrivacySettings)))
        }
        if case .attention = status {
            menu.addItem(item("Clear Warning", #selector(clearWarning)))
        }
        let paused = status == .paused
        menu.addItem(item(paused ? "Resume Monitoring" : "Pause Monitoring", #selector(togglePause)))

        let recentItem = NSMenuItem(title: "Recent Activity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let entries = service?.log.recent(15) ?? []
        if entries.isEmpty {
            let none = NSMenuItem(title: "No activity yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        } else {
            let f = DateFormatter()
            f.dateFormat = "MMM d HH:mm"
            for e in entries.reversed() {
                let mark = e.level == .info ? "" : "⚠︎ "
                let it = NSMenuItem(title: "\(f.string(from: e.date))  \(mark)\(e.message)", action: nil, keyEquivalent: "")
                it.isEnabled = false
                sub.addItem(it)
            }
        }
        sub.addItem(.separator())
        sub.addItem(item("Open Full Log", #selector(openLog)))
        recentItem.submenu = sub
        menu.addItem(recentItem)

        menu.addItem(.separator())
        menu.addItem(item("Quit FileShift", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    @objc private func togglePause() {
        if status == .paused {
            defaults.set(false, forKey: "paused")
            service?.resume()
        } else {
            defaults.set(true, forKey: "paused")
            service?.pause()
        }
    }

    @objc private func clearWarning() { service?.acknowledgeAttention() }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        // Exit status 0: the LaunchAgent (KeepAlive SuccessfulExit=false) will not relaunch until next login.
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
