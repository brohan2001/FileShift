import Foundation

/// Thrown by test hooks to simulate the process dying mid-transaction:
/// the shifter re-throws it without rolling back, leaving the journal behind.
public struct SimulatedCrash: Error {
    public init() {}
}

/// Plans and executes one versioning transaction for a newly downloaded file.
public final class VersionShifter {
    public enum Outcome: Equatable {
        /// Nothing to do (not a duplicate name, no earlier version, file changed...).
        case notApplicable(String)
        /// Something in the chain is still busy (download in progress / unclassified); retry later.
        case deferred(String)
        /// Completed successfully.
        case shifted(ShiftTransaction)
        /// Aborted; all completed steps were undone (or files rescued to visible names).
        case failed(String)
    }

    public let directory: String
    let journal: Journal
    let log: ActivityLog

    /// Test hooks, called around every step with its index.
    public var beforeStep: ((Int, ShiftStep) throws -> Void)?
    public var afterStep: ((Int, ShiftStep) throws -> Void)?

    public init(directory: String, journal: Journal, log: ActivityLog) {
        self.directory = directory
        self.journal = journal
        self.log = log
    }

    private func path(_ name: String) -> String { (directory as NSString).appendingPathComponent(name) }

    private struct Occupant {
        let name: String
        let stat: FileStat
    }

    /// Processes the new file `name`.
    /// - Parameters:
    ///   - expectedInode: the inode that was confirmed stable; if the file at `name` differs, nothing happens.
    ///   - isBlocked: return true for an existing chain member that must not be moved yet
    ///     (e.g. another pending download). Temp-sibling checks are always applied.
    public func process(name: String,
                        expectedInode: UInt64? = nil,
                        isBlocked: (String, FileStat) -> Bool = { _, _ in false }) throws -> Outcome {
        guard let vn = VersionName.parse(name) else { return .notApplicable("not a numbered duplicate") }
        guard let incoming = try SafeFS.stat(path(name)) else { return .notApplicable("file no longer exists") }
        guard incoming.isRegular else { return .notApplicable("not a regular file") }
        if let e = expectedInode, incoming.inode != e { return .notApplicable("file was replaced") }

        // Actual on-disk names, so that case/normalisation differences resolve to the real entry.
        let listing = try SafeFS.listDirectory(directory)
        var actualName: [String: String] = [:]
        for n in listing { actualName[SafeFS.nameKey(n)] = n }

        func occupants(_ slot: Int) throws -> [Occupant] {
            let candidates = slot == 0
                ? [vn.cleanName]
                : [vn.name(forSlot: slot, spaced: false), vn.name(forSlot: slot, spaced: true)]
            var result: [Occupant] = []
            var seen = Set<UInt64>()
            for c in candidates {
                guard let st = try SafeFS.stat(path(c)), st.inode != incoming.inode, !seen.contains(st.inode) else { continue }
                seen.insert(st.inode)
                result.append(Occupant(name: actualName[SafeFS.nameKey(c)] ?? c, stat: st))
            }
            return result
        }

        // Is there any earlier version at all? Otherwise leave the file alone.
        var hasFamily = false
        for slot in 0..<vn.number where !(try occupants(slot)).isEmpty { hasFamily = true; break }
        guard hasFamily else { return .notApplicable("no earlier version of \(vn.cleanName)") }

        // Contiguous run of occupied slots starting at 0 (incoming's own slot counts as free).
        var run: [[Occupant]] = []
        while run.count < 100_000 {
            let occ = try occupants(run.count)
            if occ.isEmpty { break }
            run.append(occ)
        }

        for slotOccupants in run {
            for o in slotOccupants {
                if !o.stat.isRegular {
                    return .notApplicable("\(o.name) is not a regular file (folder/link); leaving family untouched")
                }
                if DownloadRules.hasTemporarySibling(o.name, in: directory) {
                    return .deferred("\(o.name) is still being downloaded")
                }
                if isBlocked(o.name, o.stat) {
                    return .deferred("\(o.name) is not settled yet")
                }
            }
        }

        // Build steps.
        let txid = Self.makeTransactionID()
        var steps: [ShiftStep] = []
        if run.isEmpty {
            steps.append(ShiftStep(from: name, to: vn.cleanName, inode: incoming.inode, size: incoming.size))
        } else {
            let stagingExt = vn.ext.utf8.count <= 32 ? vn.ext : ""
            let staging = "\(Recovery.stagingPrefix)\(txid)\(stagingExt)"
            steps.append(ShiftStep(from: name, to: staging, inode: incoming.inode, size: incoming.size))
            for slot in stride(from: run.count - 1, through: 0, by: -1) {
                for o in run[slot] {
                    let target = Self.targetName(for: o.name, slot: slot, family: vn)
                    steps.append(ShiftStep(from: o.name, to: target, inode: o.stat.inode, size: o.stat.size))
                }
            }
            steps.append(ShiftStep(from: staging, to: vn.cleanName, inode: incoming.inode, size: incoming.size))
        }

        // Pre-flight: simulate the sequence against the listing; refuse before touching anything on conflict.
        var present = Set(listing.map(SafeFS.nameKey))
        for step in steps {
            let f = SafeFS.nameKey(step.from), t = SafeFS.nameKey(step.to)
            guard present.contains(f) else { return .failed("pre-flight: \(step.from) missing") }
            guard !present.contains(t) else {
                log.warn("Pre-flight collision: \(step.to) already exists; leaving \(name) untouched")
                return .failed("pre-flight: destination \(step.to) already exists")
            }
            present.remove(f)
            present.insert(t)
        }

        let tx = ShiftTransaction(id: txid, directory: directory, created: Date(),
                                  incoming: name, cleanName: vn.cleanName, steps: steps)
        return try execute(tx)
    }

    /// Name for an occupant of `slot` after moving one slot back. Keeps the
    /// occupant's own spelling; the clean original takes the incoming file's spelling.
    static func targetName(for occupantName: String, slot: Int, family: VersionName) -> String {
        if slot > 0, let p = VersionName.parse(occupantName) {
            return p.name(forSlot: slot + 1, spaced: p.spaced)
        }
        // Clean original: keep its actual base/extension casing.
        let ext = family.ext
        let base: String
        let realExt: String
        if !ext.isEmpty, occupantName.count > ext.count,
           SafeFS.nameKey(String(occupantName.suffix(ext.count))) == SafeFS.nameKey(ext) {
            base = String(occupantName.dropLast(ext.count))
            realExt = String(occupantName.suffix(ext.count))
        } else if ext.isEmpty {
            base = occupantName
            realExt = ""
        } else {
            base = family.base
            realExt = ext
        }
        return VersionName(base: base, ext: realExt, number: slot + 1, spaced: family.spaced)
            .name(forSlot: slot + 1, spaced: family.spaced)
    }

    static func makeTransactionID() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let rand = UUID().uuidString.prefix(8).lowercased()
        return "\(f.string(from: Date()))-\(rand)"
    }

    private func execute(_ tx: ShiftTransaction) throws -> Outcome {
        try journal.record(tx)   // write-ahead: durable before the first rename
        log.info("Tx \(tx.id) begin: \(tx.incoming) -> \(tx.cleanName), \(tx.steps.count) steps")
        do {
            for (i, step) in tx.steps.enumerated() {
                try beforeStep?(i, step)
                guard let st = try SafeFS.stat(tx.path(step.from)), st.inode == step.inode else {
                    throw FSError(op: "verify", path: tx.path(step.from), code: ESTALE)
                }
                try SafeFS.renameExclusive(tx.path(step.from), tx.path(step.to))
                SafeFS.fsyncDirectory(directory)
                log.info("Tx \(tx.id) step \(i): \(step.from) -> \(step.to) [inode \(step.inode), \(step.size) bytes]")
                try afterStep?(i, step)
            }
        } catch let crash as SimulatedCrash {
            throw crash
        } catch {
            log.error("Tx \(tx.id) failed: \(error). Rolling back.")
            let report = Recovery.rollBack(tx, log: log)
            journal.complete(tx)
            if report.problems.isEmpty {
                log.activity("Could not version \(tx.cleanName) (\(error)); nothing changed", level: .warn)
            } else {
                log.activity("Could not version \(tx.cleanName); files kept, see log: \(report.problems.joined(separator: "; "))", level: .error)
            }
            if let fe = error as? FSError, fe.isPermission { throw fe }
            return .failed("\(error)")
        }
        journal.complete(tx)
        let shifted = tx.steps.count > 1 ? tx.steps.count - 2 : 0
        log.info("Tx \(tx.id) committed")
        log.activity(shifted == 0
            ? "\(tx.incoming) → \(tx.cleanName)"
            : "\(tx.incoming) → \(tx.cleanName); \(shifted) older version\(shifted == 1 ? "" : "s") shifted")
        return .shifted(tx)
    }
}
