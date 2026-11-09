import Foundation
import Darwin

/// Snapshot of `lstat` for one directory entry.
public struct FileStat: Equatable {
    public let inode: UInt64
    public let size: Int64
    public let mtimeSec: Int
    public let mtimeNsec: Int
    public let mode: mode_t

    public var isRegular: Bool { (mode & S_IFMT) == S_IFREG }
    public var isDirectory: Bool { (mode & S_IFMT) == S_IFDIR }

    /// True if size and modification time are identical (inode is compared separately).
    public func sameContentSignature(as other: FileStat) -> Bool {
        size == other.size && mtimeSec == other.mtimeSec && mtimeNsec == other.mtimeNsec
    }
}

/// A POSIX failure with the operation and path that caused it.
public struct FSError: Error, CustomStringConvertible {
    public let op: String
    public let path: String
    public let code: Int32

    public init(op: String, path: String, code: Int32) {
        self.op = op
        self.path = path
        self.code = code
    }

    public var description: String {
        "\(op) \(path): \(String(cString: strerror(code))) (errno \(code))"
    }

    /// Missing Full Disk / Files & Folders permission shows up as EPERM or EACCES.
    public var isPermission: Bool { code == EPERM || code == EACCES }
}

/// Thin, explicit wrappers over the POSIX calls FileShift relies on.
/// Everything that changes the filesystem goes through here.
public enum SafeFS {
    /// `lstat` (never follows symlinks). Returns nil if the entry does not exist.
    public static func stat(_ path: String) throws -> FileStat? {
        var st = Darwin.stat()
        if lstat(path, &st) != 0 {
            let e = errno
            if e == ENOENT || e == ENOTDIR { return nil }
            throw FSError(op: "lstat", path: path, code: e)
        }
        return FileStat(
            inode: UInt64(st.st_ino),
            size: Int64(st.st_size),
            mtimeSec: Int(st.st_mtimespec.tv_sec),
            mtimeNsec: Int(st.st_mtimespec.tv_nsec),
            mode: st.st_mode
        )
    }

    public static func exists(_ path: String) throws -> Bool {
        try stat(path) != nil
    }

    /// Atomic rename that refuses to replace an existing destination
    /// (`renamex_np` with `RENAME_EXCL`). Fails with EEXIST instead of overwriting.
    public static func renameExclusive(_ from: String, _ to: String) throws {
        if renamex_np(from, to, UInt32(RENAME_EXCL)) != 0 {
            throw FSError(op: "rename", path: "\(from) -> \(to)", code: errno)
        }
    }

    /// Flush a directory's metadata (the rename) to stable storage.
    public static func fsyncDirectory(_ path: String) {
        let fd = open(path, O_RDONLY)
        if fd >= 0 {
            _ = fsync(fd)
            close(fd)
        }
    }

    /// Lists entry names of a directory (top level only, no "." / "..").
    public static func listDirectory(_ path: String) throws -> [String] {
        guard let dir = opendir(path) else {
            throw FSError(op: "opendir", path: path, code: errno)
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let ent = readdir(dir) {
            var nameTuple = ent.pointee.d_name
            let len = Int(ent.pointee.d_namlen)
            let name = withUnsafeBytes(of: &nameTuple) { raw in
                String(decoding: raw.prefix(len), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return names
    }

    /// Writes `data` durably: temp file, F_FULLFSYNC, rename into place, fsync directory.
    public static func writeAtomically(_ data: Data, to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = path + ".tmp-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw FSError(op: "open", path: tmp, code: errno) }
        var writeErr: Int32 = 0
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var off = 0
            while off < buf.count {
                let n = write(fd, base + off, buf.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    writeErr = errno
                    return
                }
                off += n
            }
        }
        if writeErr == 0, fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
            writeErr = errno
        }
        close(fd)
        if writeErr != 0 {
            unlink(tmp)
            throw FSError(op: "write", path: tmp, code: writeErr)
        }
        if rename(tmp, path) != 0 {
            let e = errno
            unlink(tmp)
            throw FSError(op: "rename", path: "\(tmp) -> \(path)", code: e)
        }
        fsyncDirectory(dir)
    }

    /// Normalised key approximating APFS's case- and normalisation-insensitive
    /// name comparison. Used only for pre-flight planning; the real authority is
    /// always the filesystem (`RENAME_EXCL`).
    public static func nameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}
