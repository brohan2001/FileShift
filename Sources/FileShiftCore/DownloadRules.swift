import Foundation

/// Rules for recognising files that are still being downloaded.
public enum DownloadRules {
    /// Extensions used by browsers / download managers for in-progress files.
    public static let temporaryExtensions: Set<String> = [
        "part",        // Firefox
        "crdownload",  // Chrome / Chromium / Edge / Arc / Brave
        "download",    // Safari (a folder bundle) and others
        "tmp",
        "partial",     // older IE / misc
        "opdownload",  // Opera
    ]

    /// Suffixes that, appended to a final name, indicate a download still in progress
    /// for that name (e.g. Firefox keeps `report(1).pdf` + `report(1).pdf.part`).
    public static let siblingSuffixes = [".part", ".crdownload", ".download", ".tmp", ".partial", ".opdownload"]

    /// Hidden files, our own staging files and temp-extension files are never candidates.
    public static func isTemporaryOrHidden(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return temporaryExtensions.contains(ext)
    }

    /// True if an in-progress companion of `name` exists in `directory`.
    public static func hasTemporarySibling(_ name: String, in directory: String) -> Bool {
        for suffix in siblingSuffixes {
            let p = (directory as NSString).appendingPathComponent(name + suffix)
            if (try? SafeFS.exists(p)) == true { return true }
        }
        return false
    }
}
