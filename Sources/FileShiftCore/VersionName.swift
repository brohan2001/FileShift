import Foundation

/// A browser-generated duplicate name such as `report(3).pdf` (Firefox) or
/// `report (3).pdf` (Chrome/Chromium), split into its parts.
///
/// The `(N)` suffix anchors the parse: everything after it must be either
/// nothing or a run of `.ext` components (so `archive(1).tar.gz` and
/// `my.project.final(1).pdf` both work), and everything before it is the base.
public struct VersionName: Equatable, CustomStringConvertible {
    /// Name without the suffix and without the extension, e.g. `my.project.final`.
    public let base: String
    /// Extension including the leading dot(s), e.g. `.pdf`, `.tar.gz`, or `""`.
    public let ext: String
    /// The duplicate number N (always >= 1 for a parsed name).
    public let number: Int
    /// `true` for `base (N).ext` (Chrome style), `false` for `base(N).ext` (Firefox style).
    public let spaced: Bool

    public init(base: String, ext: String, number: Int, spaced: Bool) {
        self.base = base
        self.ext = ext
        self.number = number
        self.spaced = spaced
    }

    /// The clean, unsuffixed filename: `base + ext`.
    public var cleanName: String { base + ext }

    public var description: String { name(forSlot: number, spaced: spaced) }

    /// Name for slot `n` of this family. Slot 0 is the clean name.
    public func name(forSlot n: Int, spaced: Bool) -> String {
        if n == 0 { return cleanName }
        return "\(base)\(spaced ? " " : "")(\(n))\(ext)"
    }

    private static let regex: NSRegularExpression = {
        // base: lazy, at least one char. sep: optional single space.
        // number: 1-6 digits, no leading zero. ext: zero or more ".xxx" parts
        // where xxx has no dots, whitespace, or parentheses.
        let pattern = #"^(.+?)( ?)\(([1-9][0-9]{0,5})\)((?:\.[^.\s()/]+)*)$"#
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Parses a numbered duplicate name. Returns `nil` for names without a
    /// trailing `(N)` suffix (including clean names) and for hidden files.
    public static func parse(_ filename: String) -> VersionName? {
        if filename.hasPrefix(".") { return nil }
        let ns = filename as NSString
        guard let m = regex.firstMatch(in: filename, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let base = ns.substring(with: m.range(at: 1))
        let sep = ns.substring(with: m.range(at: 2))
        let numStr = ns.substring(with: m.range(at: 3))
        let ext = m.range(at: 4).location == NSNotFound ? "" : ns.substring(with: m.range(at: 4))
        guard let number = Int(numStr), number >= 1 else { return nil }
        // A base that is only whitespace (e.g. " (1).pdf") is not a real family.
        if base.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        return VersionName(base: base, ext: ext, number: number, spaced: sep == " ")
    }

    /// Splits a plain filename into (stem, extension) at the last dot.
    /// Used for building human-readable recovery names.
    public static func splitExtension(_ name: String) -> (stem: String, ext: String) {
        let ns = name as NSString
        let ext = ns.pathExtension
        if ext.isEmpty || ext.count > 16 || ns.deletingPathExtension.isEmpty { return (name, "") }
        return (ns.deletingPathExtension, "." + ext)
    }
}
