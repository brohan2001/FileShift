import Foundation

/// Orchestrates watching, download-completion detection and versioning for one directory.
/// All mutable state is confined to a private serial queue.
public final class FileShiftService {
    public struct Configuration {
        public var directory: String
        public var journalDirectory: String
        public var logFile: String?
        /// Seconds between stability samples while candidates are pending.
        public var sampleInterval: TimeInterval = 1.0
        /// Consecutive unchanged samples (with no temp sibling) required before acting.
        public var requiredStableSamples: Int = 3
        /// Delay to coalesce bursts of directory events into one listing.
        public var debounce: TimeInterval = 0.3
        /// Give up on a candidate that never settles after this long.
        public var maxPendingAge: TimeInterval = 24 * 3600
        /// An empty file is treated as a browser placeholder (Firefox creates a 0-byte file at
        /// the final name while the data goes to a separately named temp file) and is never
        /// versioned. After this long it is left alone for good.
        public var emptyFileGiveUp: TimeInterval = 600
        /// Retry interval after a permission error.
        public var permissionRetry: TimeInterval = 15

        public init(directory: String, journalDirectory: String, logFile: String?) {
            self.directory = directory
            self.journalDirectory = journalDirectory
            self.logFile = logFile
        }
    }

    public enum Status: Equatable {
        case stopped
        case active
        case paused
        case needsAccess(String)
        case attention(String)
    }

    public let config: Configuration
    public let log: ActivityLog
    public var onStatusChange: ((Status) -> Void)?

    private let queue = DispatchQueue(label: "io.github.brohan2001.fileshift.service")
    private let journal: Journal
    private let shifter: VersionShifter
    private var watcher: DirectoryWatcher?
    private var timer: DispatchSourceTimer?
    private var scanScheduled = false
    private var watching = false
    private var isPaused = false

    private var known = Set<UInt64>()
    private struct Candidate {
        var name: String
        var stat: FileStat
        var stableCount: Int
        let firstSeen: Date
        var deferredLogged = false
    }
    private var pending: [UInt64: Candidate] = [:]

    private var _status: Status = .stopped
    private var statusLock = NSLock()
    public var status: Status {
        statusLock.lock(); defer { statusLock.unlock() }
        return _status
    }
    private func setStatus(_ s: Status) {
        statusLock.lock()
        let changed = _status != s
        _status = s
        statusLock.unlock()
        if changed { onStatusChange?(s) }
    }

    /// Number of transactions committed since start (for tests/diagnostics).
    public private(set) var committedCount = 0

    public init(config: Configuration) throws {
        self.config = config
        self.log = ActivityLog(filePath: config.logFile)
        self.journal = try Journal(directory: config.journalDirectory)
        self.shifter = VersionShifter(directory: config.directory, journal: journal, log: log)
    }

    // MARK: - Public control (thread-safe)

    public func start(paused: Bool = false) {
        queue.async {
            self.log.info("FileShift starting; directory=\(self.config.directory)")
            self.runRecovery()
            if paused {
                self.isPaused = true
                self.setStatus(.paused)
                self.log.info("Starting paused")
            } else {
                self.beginWatching()
            }
        }
    }

    public func pause() {
        queue.async {
            guard !self.isPaused else { return }
            self.isPaused = true
            self.endWatching()
            self.setStatus(.paused)
            self.log.activity("Monitoring paused")
        }
    }

    public func resume() {
        queue.async {
            guard self.isPaused else { return }
            self.isPaused = false
            self.log.activity("Monitoring resumed")
            self.beginWatching()
        }
    }

    public func stop() {
        queue.sync {
            self.endWatching()
            self.setStatus(.stopped)
        }
    }

    /// Clears an attention state after the user has seen it.
    public func acknowledgeAttention() {
        queue.async {
            if case .attention = self.status { self.setStatus(self.watching ? .active : .paused) }
        }
    }

    /// Runs `block` on the service queue and waits (tests/diagnostics).
    public func sync<T>(_ block: () -> T) -> T { queue.sync(execute: block) }

    public var pendingCount: Int { queue.sync { pending.count } }

    // MARK: - Lifecycle (queue-confined)

    private func runRecovery() {
        let recovery = Recovery(journal: journal, log: log)
        let report = recovery.recoverAll(orphanScanDirectory: config.directory)
        if !report.isEmpty { log.warn("Recovery report: \(report)") }
        if report.needsAttention {
            setStatus(.attention("Recovered files after an interruption — see Recent Activity"))
        }
    }

    private func beginWatching() {
        guard !isPaused else { return }
        endWatching()
        let w = DirectoryWatcher(path: config.directory, queue: queue,
                                 onChange: { [weak self] in self?.scheduleScan() },
                                 onError: { [weak self] e in self?.handlePermissionOrError(e) })
        do {
            // Watch first, then baseline: anything arriving in between is treated as pre-existing (safe side).
            try w.start()
            watcher = w
            try takeBaseline()
            watching = true
            if case .attention = status {} else { setStatus(.active) }
            log.info("Monitoring \(config.directory) (\(known.count) existing entries ignored)")
        } catch let e as FSError {
            w.stop()
            watcher = nil
            handlePermissionOrError(e)
        } catch {
            log.error("Could not start monitoring: \(error)")
        }
    }

    private func endWatching() {
        watcher?.stop()
        watcher = nil
        timer?.cancel()
        timer = nil
        pending.removeAll()
        known.removeAll()
        watching = false
    }

    private func handlePermissionOrError(_ e: FSError) {
        if e.isPermission {
            log.error("Permission denied: \(e). Grant FileShift access to the Downloads folder.")
            setStatus(.needsAccess("FileShift needs permission to access the Downloads folder"))
        } else {
            log.error("Monitoring error: \(e)")
            setStatus(.attention("Error: \(e)"))
        }
        endWatching()
        queue.asyncAfter(deadline: .now() + config.permissionRetry) { [weak self] in
            guard let self, !self.isPaused, !self.watching else { return }
            self.beginWatching()
        }
    }

    private func takeBaseline() throws {
        known.removeAll()
        pending.removeAll()
        for name in try SafeFS.listDirectory(config.directory) where !DownloadRules.isTemporaryOrHidden(name) {
            if let st = try? SafeFS.stat(path(name)) { known.insert(st.inode) }
        }
    }

    private func path(_ name: String) -> String { (config.directory as NSString).appendingPathComponent(name) }

    // MARK: - Scanning

    private func scheduleScan() {
        guard watching, !scanScheduled else { return }
        scanScheduled = true
        queue.asyncAfter(deadline: .now() + config.debounce) { [weak self] in
            guard let self else { return }
            self.scanScheduled = false
            self.scan()
        }
    }

    /// Lists the top level and classifies entries whose inode has not been seen.
    private func scan() {
        guard watching else { return }
        let names: [String]
        do {
            names = try SafeFS.listDirectory(config.directory)
        } catch let e as FSError {
            handlePermissionOrError(e)
            return
        } catch { return }

        var present = Set<UInt64>()
        for name in names {
            // Temp files are tracked by nobody: their inode may become the final file
            // (Firefox renames x.part onto the final name), so they must not become "known".
            if DownloadRules.isTemporaryOrHidden(name) { continue }
            guard let st = try? SafeFS.stat(path(name)) else { continue }
            present.insert(st.inode)
            if known.contains(st.inode) { continue }
            if !st.isRegular {
                known.insert(st.inode)
                continue
            }
            if var c = pending[st.inode] {
                if c.name != name { c.name = name; c.stableCount = 0 }
                pending[st.inode] = c
                continue
            }
            guard VersionName.parse(name) != nil else {
                known.insert(st.inode)   // a new file with a clean name: nothing to do
                continue
            }
            pending[st.inode] = Candidate(name: name, stat: st, stableCount: 0, firstSeen: Date())
            log.info("Detected new download \(name) [inode \(st.inode)]; waiting for it to finish")
        }
        for inode in pending.keys where !present.contains(inode) {
            log.debug("Candidate inode \(inode) disappeared (\(pending[inode]!.name))")
            pending.removeValue(forKey: inode)
        }
        updateTimer()
    }

    private func updateTimer() {
        if pending.isEmpty {
            timer?.cancel()
            timer = nil
        } else if timer == nil {
            let t = DispatchSource.makeTimerSource(queue: queue)
            let ms = Int(config.sampleInterval * 1000)
            t.schedule(deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms), leeway: .milliseconds(max(ms / 10, 10)))
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.resume()
        }
    }

    // MARK: - Stability + processing

    private func tick() {
        guard watching else { return }
        let now = Date()
        for (inode, var c) in pending {
            guard let st = try? SafeFS.stat(path(c.name)), st.inode == inode else {
                pending.removeValue(forKey: inode)   // replaced or moved; next scan re-classifies
                scheduleScan()
                continue
            }
            if st.size == 0 {
                // Placeholder: the real data arrives later under a new inode, which drops this candidate.
                c.stableCount = 0
                if now.timeIntervalSince(c.firstSeen) > config.emptyFileGiveUp {
                    log.info("Leaving empty file \(c.name) alone")
                    known.insert(inode)
                    pending.removeValue(forKey: inode)
                    continue
                }
            } else if DownloadRules.hasTemporarySibling(c.name, in: config.directory) {
                c.stableCount = 0
            } else if st.sameContentSignature(as: c.stat) {
                c.stableCount += 1
            } else {
                c.stableCount = 0
            }
            c.stat = st
            if now.timeIntervalSince(c.firstSeen) > config.maxPendingAge {
                log.warn("Giving up on \(c.name): it never stopped changing")
                known.insert(inode)
                pending.removeValue(forKey: inode)
                continue
            }
            pending[inode] = c
        }

        let ready = pending.filter { $0.value.stableCount >= config.requiredStableSamples }
            .sorted { a, b in
                let ma = (a.value.stat.mtimeSec, a.value.stat.mtimeNsec), mb = (b.value.stat.mtimeSec, b.value.stat.mtimeNsec)
                if ma != mb { return ma < mb }
                return (VersionName.parse(a.value.name)?.number ?? 0) < (VersionName.parse(b.value.name)?.number ?? 0)
            }
        if !ready.isEmpty {
            scan()   // classify anything new before touching the chain
            for (inode, _) in ready {
                guard watching, let c = pending[inode], c.stableCount >= config.requiredStableSamples else { continue }
                process(inode: inode, candidate: c)
            }
        }
        updateTimer()
    }

    private func process(inode: UInt64, candidate c: Candidate) {
        do {
            let outcome = try shifter.process(name: c.name, expectedInode: inode) { [known] _, st in
                !known.contains(st.inode)
            }
            switch outcome {
            case .shifted(let tx):
                committedCount += 1
                for step in tx.steps { known.insert(step.inode) }
                pending.removeValue(forKey: inode)
            case .notApplicable(let why):
                log.info("No action for \(c.name): \(why)")
                known.insert(inode)
                pending.removeValue(forKey: inode)
            case .deferred(let why):
                if !c.deferredLogged {
                    log.info("Deferring \(c.name): \(why)")
                    pending[inode]?.deferredLogged = true
                }
            case .failed(let why):
                log.error("Versioning \(c.name) failed: \(why)")
                known.insert(inode)
                pending.removeValue(forKey: inode)
                setStatus(.attention("Could not version \(c.name) — see log"))
            }
        } catch let e as FSError where e.isPermission {
            handlePermissionOrError(e)
        } catch {
            log.error("Unexpected error processing \(c.name): \(error)")
            known.insert(inode)
            pending.removeValue(forKey: inode)
            setStatus(.attention("Error processing \(c.name) — see log"))
        }
    }
}
