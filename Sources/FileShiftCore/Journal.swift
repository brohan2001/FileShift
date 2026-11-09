import Foundation

/// One rename in a shift transaction. Names are relative to the transaction's directory.
public struct ShiftStep: Codable, Equatable {
    public var from: String
    public var to: String
    public var inode: UInt64
    public var size: Int64
}

/// A planned, journaled sequence of renames.
public struct ShiftTransaction: Codable, Equatable {
    public var id: String
    public var directory: String
    public var created: Date
    /// Name the incoming download had when it was detected.
    public var incoming: String
    /// Clean name the incoming download ends up with.
    public var cleanName: String
    public var steps: [ShiftStep]

    public func path(_ name: String) -> String { (directory as NSString).appendingPathComponent(name) }
}

/// Write-ahead log of in-flight transactions. A journal file exists exactly
/// while its transaction might have been partially applied.
public final class Journal {
    public let directory: String

    public init(directory: String) throws {
        self.directory = directory
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    private func path(for id: String) -> String {
        (directory as NSString).appendingPathComponent("\(id).json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Durably records a transaction *before* any of its renames happen.
    public func record(_ tx: ShiftTransaction) throws {
        let data = try Self.encoder.encode(tx)
        try SafeFS.writeAtomically(data, to: path(for: tx.id))
    }

    /// Removes the journal entry once the transaction is fully applied or resolved.
    /// This is the only file deletion FileShift ever performs.
    public func complete(_ tx: ShiftTransaction) {
        unlink(path(for: tx.id))
        SafeFS.fsyncDirectory(directory)
    }

    public struct Entry {
        public let path: String
        public let transaction: ShiftTransaction?
    }

    /// All journal entries still present (i.e. possibly interrupted transactions).
    public func pending() -> [Entry] {
        guard let names = try? SafeFS.listDirectory(directory) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.sorted().map { name in
            let p = (directory as NSString).appendingPathComponent(name)
            let tx = FileManager.default.contents(atPath: p).flatMap { try? Self.decoder.decode(ShiftTransaction.self, from: $0) }
            return Entry(path: p, transaction: tx)
        }
    }

    /// Moves an unreadable journal aside so it is kept for diagnosis but not retried forever.
    public func quarantine(_ entry: Entry) {
        let dst = entry.path + ".corrupt"
        _ = try? SafeFS.renameExclusive(entry.path, dst)
    }
}
