import Foundation
import FileShiftCore

// Debug / test tool. Never defaults to ~/Downloads: every command needs an explicit directory.

func usage() -> Never {
    let text = """
    usage:
      fileshift-cli parse <filename>
      fileshift-cli shift <dir> <filename> --journal <dir> [--crash-after-step N] [--log FILE]
      fileshift-cli recover <dir> --journal <dir> [--log FILE]
      fileshift-cli watch <dir> --journal <dir> [--log FILE] [--interval SECONDS] [--samples N]

    """
    FileHandle.standardError.write(text.data(using: .utf8)!)
    exit(64)
}

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

guard let command = args.first else { usage() }
args.removeFirst()
let journalDir = option("--journal")
let logFile = option("--log")
let crashAfter = option("--crash-after-step").flatMap(Int.init)
let interval = option("--interval").flatMap(Double.init)
let samples = option("--samples").flatMap(Int.init)

func absolute(_ p: String) -> String {
    p.hasPrefix("/") ? p : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(p)
}

switch command {
case "parse":
    guard let name = args.first else { usage() }
    if let v = VersionName.parse(name) {
        print("base=\"\(v.base)\" ext=\"\(v.ext)\" number=\(v.number) spaced=\(v.spaced) clean=\"\(v.cleanName)\"")
    } else {
        print("not a numbered duplicate")
    }

case "shift":
    guard args.count >= 2, let journalDir else { usage() }
    let dir = absolute(args[0])
    let log = ActivityLog(filePath: logFile)
    log.echo = true
    let shifter = VersionShifter(directory: dir, journal: try Journal(directory: absolute(journalDir)), log: log)
    if let k = crashAfter {
        // Simulate an abrupt process death right after step k (no cleanup, no rollback).
        shifter.afterStep = { i, _ in if i == k { exit(3) } }
    }
    let outcome = try shifter.process(name: args[1])
    print("\(outcome)")

case "recover":
    guard let dirArg = args.first, let journalDir else { usage() }
    let log = ActivityLog(filePath: logFile)
    log.echo = true
    let report = Recovery(journal: try Journal(directory: absolute(journalDir)), log: log)
        .recoverAll(orphanScanDirectory: absolute(dirArg))
    print("\(report)")

case "watch":
    guard let dirArg = args.first, let journalDir else { usage() }
    var config = FileShiftService.Configuration(directory: absolute(dirArg), journalDirectory: absolute(journalDir), logFile: logFile)
    if let interval { config.sampleInterval = interval }
    if let samples { config.requiredStableSamples = samples }
    let service = try FileShiftService(config: config)
    service.log.echo = true
    service.onStatusChange = { s in FileHandle.standardError.write("status: \(s)\n".data(using: .utf8)!) }
    signal(SIGINT) { _ in exit(0) }
    signal(SIGTERM) { _ in exit(0) }
    service.start()
    dispatchMain()

default:
    usage()
}
