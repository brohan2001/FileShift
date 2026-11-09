import Foundation

/// Brings interrupted transactions to a consistent state.
///
/// Every step records the inode it moves, so the progress of a transaction can
/// be read back from the filesystem itself: for each file we look for its inode
/// along the chain of names it was supposed to travel through.
///
/// Strategy: roll forward if every file is found and every remaining target is
/// free; otherwise undo completed steps in reverse order. Any file still sitting
/// on a hidden staging name is finally given a visible "recovered" name.
/// Nothing is ever deleted or overwritten (all renames use RENAME_EXCL).
public final class Recovery {
    public static let stagingPrefix = ".fileshift-"

    public struct Report: CustomStringConvertible {
        public var rolledForward: [String] = []
        public var rolledBack: [String] = []
        public var recoveredFiles: [String] = []
        public var problems: [String] = []
        public var needsAttention: Bool { !problems.isEmpty || !recoveredFiles.isEmpty }
        public var isEmpty: Bool { rolledForward.isEmpty && rolledBack.isEmpty && recoveredFiles.isEmpty && problems.isEmpty }
        public var description: String {
            "rolledForward=\(rolledForward) rolledBack=\(rolledBack) recovered=\(recoveredFiles) problems=\(problems)"
        }
    }

    let journal: Journal
    let log: ActivityLog

    public init(journal: Journal, log: ActivityLog) {
        self.journal = journal
        self.log = log
    }

    /// Recovers every pending journal entry, then rescues orphaned staging
    /// files in `orphanScanDirectory` (if given).
    @discardableResult
    public func recoverAll(orphanScanDirectory: String?) -> Report {
        var report = Report()
        for entry in journal.pending() {
            guard let tx = entry.transaction else {
                report.problems.append("unreadable journal \(entry.path)")
                log.error("Recovery: unreadable journal \(entry.path); moved aside as .corrupt")
                journal.quarantine(entry)
                continue
            }
            log.warn("Recovery: found interrupted transaction \(tx.id) for \(tx.cleanName) in \(tx.directory)")
            if Self.rollForward(tx, log: log) {
                report.rolledForward.append(tx.id)
                log.activity("Recovered interrupted shift of \(tx.cleanName) (completed)")
            } else {
                let r = Self.rollBack(tx, log: log)
                report.rolledBack.append(tx.id)
                report.recoveredFiles += r.recoveredFiles
                report.problems += r.problems
                log.activity("Recovered interrupted shift of \(tx.cleanName) (undone)", level: r.problems.isEmpty ? .info : .warn)
            }
            journal.complete(tx)
        }
        if let dir = orphanScanDirectory {
            let r = rescueOrphans(in: dir)
            report.recoveredFiles += r.recoveredFiles
            report.problems += r.problems
        }
        return report
    }

    // MARK: - Chain bookkeeping

    /// For each inode: the ordered list of names it travels through, and for each
    /// step its position within that chain.
    struct Chains {
        var chain: [UInt64: [String]] = [:]
        var position: [Int] = [] // per step: index of step.from within chain[inode]

        init(_ tx: ShiftTransaction) {
            for step in tx.steps {
                if chain[step.inode] == nil { chain[step.inode] = [step.from] }
                position.append(chain[step.inode]!.count - 1)
                chain[step.inode]!.append(step.to)
            }
        }
    }

    /// Current index of each inode along its chain, or nil if not found on any of its names.
    static func locate(_ tx: ShiftTransaction, _ chains: Chains) -> [UInt64: Int?] {
        var result: [UInt64: Int?] = [:]
        for (inode, names) in chains.chain {
            var found: Int? = nil
            for (idx, name) in names.enumerated().reversed() {
                if let st = try? SafeFS.stat(tx.path(name)), st.inode == inode { found = idx; break }
            }
            result[inode] = found
        }
        return result
    }

    // MARK: - Roll forward

    /// Completes the remaining steps. Returns false (having changed nothing that
    /// cannot be undone by `rollBack`) if any precondition does not hold.
    static func rollForward(_ tx: ShiftTransaction, log: ActivityLog) -> Bool {
        let chains = Chains(tx)
        var loc = locate(tx, chains)
        if loc.values.contains(where: { $0 == nil }) {
            log.warn("Recovery \(tx.id): a file is missing from its expected names; will undo instead")
            return false
        }
        for (i, step) in tx.steps.enumerated() {
            let j = chains.position[i]
            guard let current = loc[step.inode] ?? nil else { return false }
            if current > j { continue }        // already done
            if current < j { return false }    // inconsistent
            do {
                guard try !SafeFS.exists(tx.path(step.to)) else {
                    log.warn("Recovery \(tx.id): target \(step.to) is occupied; will undo instead")
                    return false
                }
                try SafeFS.renameExclusive(tx.path(step.from), tx.path(step.to))
                SafeFS.fsyncDirectory(tx.directory)
                log.info("Recovery \(tx.id): step \(i) \(step.from) -> \(step.to) [inode \(step.inode)]")
                loc[step.inode] = j + 1
            } catch {
                log.warn("Recovery \(tx.id): roll forward failed at step \(i): \(error)")
                return false
            }
        }
        return true
    }

    // MARK: - Roll back

    /// Undoes completed steps in reverse order, then makes sure no file is left
    /// on a hidden staging name. Never deletes or overwrites.
    public static func rollBack(_ tx: ShiftTransaction, log: ActivityLog) -> Report {
        var report = Report()
        let chains = Chains(tx)
        var loc = locate(tx, chains)
        for (i, step) in tx.steps.enumerated().reversed() {
            let j = chains.position[i]
            guard let current = loc[step.inode] ?? nil, current == j + 1 else { continue }
            do {
                if try SafeFS.exists(tx.path(step.from)) {
                    report.problems.append("cannot restore \(step.to) to \(step.from): name now in use")
                    log.warn("Rollback \(tx.id): \(step.from) is occupied; leaving \(step.to) where it is")
                    continue
                }
                try SafeFS.renameExclusive(tx.path(step.to), tx.path(step.from))
                SafeFS.fsyncDirectory(tx.directory)
                log.info("Rollback \(tx.id): undo step \(i) \(step.to) -> \(step.from) [inode \(step.inode)]")
                loc[step.inode] = j
            } catch {
                report.problems.append("undo of step \(i) failed: \(error)")
                log.error("Rollback \(tx.id): undo of step \(i) failed: \(error)")
            }
        }
        // Rescue anything still on a hidden staging name.
        for (inode, idxOpt) in loc {
            guard let idx = idxOpt, let names = chains.chain[inode] else {
                if idxOpt == nil {
                    report.problems.append("inode \(inode) not found on any expected name")
                    log.warn("Rollback \(tx.id): inode \(inode) not found on any expected name (moved or deleted externally?)")
                }
                continue
            }
            let name = names[idx]
            if name.hasPrefix(stagingPrefix) {
                if let visible = moveToRecoveredName(directory: tx.directory, from: name, originalName: names[0], log: log) {
                    report.recoveredFiles.append(visible)
                } else {
                    report.problems.append("could not rescue staged file \(name)")
                }
            }
        }
        return report
    }

    // MARK: - Orphans

    /// Any `.fileshift-*` file with no journal left (should never happen) is made visible.
    func rescueOrphans(in directory: String) -> Report {
        var report = Report()
        guard let names = try? SafeFS.listDirectory(directory) else { return report }
        for name in names where name.hasPrefix(Self.stagingPrefix) {
            // Staging names look like ".fileshift-<txid><ext>".
            let rest = String(name.dropFirst(Self.stagingPrefix.count))
            let ext = VersionName.splitExtension(rest).ext
            let original = "FileShift recovered file" + ext
            log.warn("Recovery: orphaned staging file \(name)")
            if let v = Self.moveToRecoveredName(directory: directory, from: name, originalName: original, log: log) {
                report.recoveredFiles.append(v)
            } else {
                report.problems.append("could not rescue \(name)")
            }
        }
        return report
    }

    /// Renames `from` to a visible, unused name derived from `originalName`, e.g.
    /// `report (FileShift recovered 2026-11-10 021530).pdf`.
    static func moveToRecoveredName(directory: String, from: String, originalName: String, log: ActivityLog) -> String? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        let stamp = f.string(from: Date())
        let (stem, ext) = VersionName.splitExtension(originalName)
        let src = (directory as NSString).appendingPathComponent(from)
        for attempt in 0..<100 {
            let suffix = attempt == 0 ? "" : " \(attempt + 1)"
            var candidate = "\(stem) (FileShift recovered \(stamp)\(suffix))\(ext)"
            if candidate.utf8.count > 250 { candidate = "FileShift recovered \(stamp)\(suffix)\(ext)" }
            let dst = (directory as NSString).appendingPathComponent(candidate)
            do {
                try SafeFS.renameExclusive(src, dst)
                SafeFS.fsyncDirectory(directory)
                log.activity("Recovered file saved as \"\(candidate)\"", level: .warn)
                return candidate
            } catch let e as FSError where e.code == EEXIST {
                continue
            } catch {
                log.error("Recovery: could not rename \(from) to \(candidate): \(error)")
                return nil
            }
        }
        return nil
    }
}
