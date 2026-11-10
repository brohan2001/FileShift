# FileShift

[![CI](https://github.com/brohan2001/FileShift/actions/workflows/ci.yml/badge.svg)](https://github.com/brohan2001/FileShift/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/brohan2001/FileShift)](https://github.com/brohan2001/FileShift/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.10%2B-orange)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A tiny native macOS menu bar utility that keeps your **newest download on the clean filename**.

When Firefox (or Chrome) saves `report.pdf` again, it names the new copy `report(3).pdf`. FileShift waits for the download to finish, then renames it to `report.pdf` and shifts the older versions back:

```
before                         after
report.pdf                     report.pdf      ← the download you just made
report(1).pdf                  report(1).pdf   ← previous report.pdf
report(2).pdf                  report(2).pdf   ← previous report(1).pdf
report(3).pdf   ← new          report(3).pdf   ← previous report(2).pdf
```

- **Native and lightweight:** Swift and Apple frameworks only, no runtime dependencies, 0% CPU when idle. It watches only the top level of `~/Downloads`, using a kernel event source rather than polling.
- **Never loses data:** atomic no-overwrite renames, a write-ahead journal, and crash recovery. Nothing is ever deleted.
- **Thoroughly tested:** 44 automated tests check file contents by checksum, plus an end-to-end test that drives a real headless Firefox. CI runs them all on every push.

## Install

Requires macOS 14 (Sonoma) or later, on Apple Silicon or Intel.

### Option 1: Homebrew (recommended)

```bash
brew install brohan2001/tap/fileshift
brew services start fileshift
```

Homebrew compiles FileShift on your Mac, so macOS shows no "unidentified developer" warning. To update later, run `brew upgrade fileshift && brew services restart fileshift`.

### Option 2: from source

Needs the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/brohan2001/FileShift.git
cd FileShift
./install.sh            # or double-click "Install FileShift.command"
```

The installer:
1. compiles a release build
2. copies it to `~/Applications/FileShift.app`
3. installs the LaunchAgent `~/Library/LaunchAgents/io.github.brohan2001.fileshift.plist`
4. starts FileShift

After that it starts automatically at every login.

### Option 3: prebuilt download (no developer tools needed)

1. Download `FileShift-vX.Y.Z-macOS.zip` from [Releases](https://github.com/brohan2001/FileShift/releases/latest) and unzip it.
2. FileShift isn't notarized by Apple (that requires a paid developer account), so install it from Terminal rather than by double-clicking:

   ```bash
   cd ~/Downloads/FileShift
   xattr -dr com.apple.quarantine .   # tell macOS you trust this download
   ./install.sh
   ```

   You can check the zip against the `.sha256` file published with each release.

### Permission prompt

The first time FileShift runs, macOS may ask whether *FileShift* can access files in your Downloads folder. Click **Allow**. Reinstalling a new build can make macOS ask again. If you clicked *Don't Allow*, see Troubleshooting.

Only one copy of FileShift runs at a time. If you install it twice (for example via Homebrew and from source), the second copy exits straight away.

## Usage

There is nothing to do: download as usual. The menu bar icon (⟳) gives you:

| Item | What it does |
|---|---|
| Status line | "Monitoring Downloads", "Paused", or a warning |
| Pause / Resume Monitoring | Pausing is remembered across restarts. Files that arrive while paused are left as they are. |
| Recent Activity | The last 15 operations, plus **Open Full Log** |
| Clear Warning | Shown after a recovery or an error, once you've read it |
| Quit FileShift | Stops it until your next login (or until you run `./install.sh` again) |

Icon states: ⟳ monitoring · ⏸ paused · ⚠︎ something needs your attention · 🔒 needs Downloads permission.

### What counts as a duplicate
- Firefox style `name(N).ext` and Chrome style `name (N).ext`, for any extension. Also handled: names with no extension, `.tar.gz`, names with several dots such as `my.project.final(2).pdf`, spaces, parentheses inside the name, and Unicode.
- Only **new** files are acted on. Everything already in Downloads when FileShift starts (or resumes) is left alone, including a file you later rename yourself.
- A numbered file is only processed if an earlier version of it exists. A lone `photo(1).jpg` is left alone.
- Numbering gaps are kept. FileShift only shifts the unbroken run of versions starting at the clean name. With `report.pdf`, `report(1).pdf` and `report(4).pdf`, a new `report(2).pdf` moves only the first two; `report(4).pdf` stays where it is.
- Folders and symlinks are never moved.

### How it knows a download has finished
FileShift does nothing while any of these is true:
- the file has a temporary extension (`.part`, `.crdownload`, `.download`, `.tmp`, `.partial`, `.opdownload`)
- the final name has a companion such as `report(1).pdf.part`. This is how Firefox works: an empty placeholder sits next to a `.part` file, and the `.part` file replaces the placeholder when the download is done.
- the file is empty. Firefox's placeholder is a 0-byte file, and its data may be written to a temp file with a different name (or outside the folder), so an empty duplicate is never treated as a finished download
- the file's size or modification time changed within the last ~3 seconds

## Safety design

- Every rename uses `renamex_np(…, RENAME_EXCL)`. This is atomic, and the kernel refuses to replace an existing file.
- Before each rename, FileShift checks that the file still has the inode (file identity) it planned for. If something else changed the folder in the meantime, the operation stops.
- **Write-ahead journal.** Before the first rename, the full plan is saved durably to `~/Library/Application Support/FileShift/journal/`. Then:
  1. The new file is moved to a hidden staging name.
  2. The older versions are shifted, highest number first.
  3. The new file takes the clean name.
  4. The journal entry is removed.
- **Crash recovery.** At startup, any leftover journal entry is resolved by finding each file by its inode. If it can safely finish the remaining steps, it does. Otherwise it undoes the completed steps. Any file that can't go back to its old name is given a visible name like `report (FileShift recovered 2026-11-10 021530).pdf`. Nothing is ever deleted.
- If anything goes wrong mid-way, it rolls back the same way and shows ⚠︎ in the menu bar.
- FileShift's own renames never trigger more processing, because it only reacts to files it has never seen before.

## Files

| Path | Purpose |
|---|---|
| `~/Applications/FileShift.app` | the app |
| `~/Library/LaunchAgents/io.github.brohan2001.fileshift.plist` | start at login, restart after a crash |
| `~/Library/Logs/FileShift/fileshift.log` | every operation (rotated at 1 MB) |
| `~/Library/Application Support/FileShift/journal/` | in-flight transactions (normally empty) |

## Troubleshooting

- **Nothing happens / 🔒 icon:** open *System Settings → Privacy & Security → Files & Folders* and enable **Downloads** for FileShift. You can also use *Grant Downloads Access…* in the menu. FileShift retries every 15 s by itself. If FileShift doesn't appear in that list, run `./install.sh` again and click Allow at the prompt.
- **Is it running?** Homebrew installs: `brew services list`. Script installs: `launchctl print gui/$(id -u)/io.github.brohan2001.fileshift | grep state`
- **Restart it:** `brew services restart fileshift`, or for script installs `launchctl kickstart -k gui/$(id -u)/io.github.brohan2001.fileshift`
- **See what it did:** `tail -f ~/Library/Logs/FileShift/fileshift.log`, or *Recent Activity → Open Full Log*.
- **Found a "FileShift recovered" file?** That file was saved by crash recovery, and its content is intact. Rename it however you like.
- **Try it safely on a test folder:**
  ```bash
  swift build
  mkdir -p /tmp/fs-try && .build/debug/fileshift-cli watch /tmp/fs-try --journal /tmp/fs-try-journal
  ```

## Uninstall

Homebrew:

```bash
brew services stop fileshift && brew uninstall fileshift
```

Source or prebuilt install:

```bash
./uninstall.sh        # or double-click "Uninstall FileShift.command"
```

The script stops FileShift and removes the LaunchAgent and the app. It then offers to delete the logs and settings. It **never touches anything in `~/Downloads`**. If a transaction journal is still pending (extremely unlikely), it is kept so a reinstall can recover it.

## Development and tests

```
Sources/FileShiftCore/   VersionName, SafeFS, Journal, Recovery, VersionShifter,
                         DownloadRules, DirectoryWatcher, FileShiftService, ActivityLog, InstanceLock
Sources/FileShift/       menu bar app (AppKit, LSUIElement)
Sources/fileshift-cli/   parse / shift / recover / watch (testing & debugging)
Tests/FileShiftCoreTests 44 XCTest cases — temp directories only, SHA-256 content checks
Tests/e2e/firefox-e2e.sh real headless Firefox, throwaway profile, temp download folder
```

```bash
swift test                    # unit + integration tests (~25 s)
Tests/e2e/firefox-e2e.sh      # real-browser test (needs Firefox; python3 only for the test server)
scripts/build-app.sh          # just build build/FileShift.app (UNIVERSAL=1 for arm64 + x86_64)
```

CI (GitHub Actions) runs the full test suite, the universal build and the Firefox end-to-end test on every push. Pushing a `v*` tag builds a universal app and publishes it as a GitHub Release.

The tests never use your real Downloads folder: the test sandbox refuses to run there. They cover:
- first, second and later downloads
- several existing versions and numbering gaps
- names with several dots, spaces, parentheses and Unicode (NFC/NFD)
- different extensions
- simultaneous downloads, both staggered and finishing at the same instant
- unfinished downloads: Firefox `.part`, Chrome `.crdownload`, Safari `.download`, and slow writers with no temp file
- a crash after every step, both simulated and as a real process kill, then recovery
- destination collisions during a transaction
- orphaned staging files and a corrupt journal
- pause/resume, ignoring subfolders, and no reprocessing of FileShift's own renames
- the single-instance lock

## How it works

1. **Watch.** A kqueue `DispatchSource` on the Downloads folder fires when entries are added, removed or renamed. Each burst of events triggers one top-level listing, compared by inode against files already seen.
2. **Wait.** A new file is acted on only when all of these hold:
   - its name looks like a browser duplicate (`name(N).ext` or `name (N).ext`)
   - an earlier version exists
   - it has no `.part`/`.crdownload`/`.download` companion
   - it is not empty (an empty file is a browser placeholder)
   - its size and modification time have stayed the same for three samples
3. **Plan.** It finds the unbroken run of existing versions starting at the clean name, and checks the whole rename sequence against the folder listing before touching anything.
4. **Journal, then rename.** It saves the plan durably, then performs `renamex_np(RENAME_EXCL)` renames with an inode check before each one and a directory `fsync` after. Finally it removes the journal entry.
5. **Recover.** At launch, leftover journal entries are finished or undone by locating each file by its inode.

## License

[MIT](LICENSE) © 2026 Rohan Balasubramanian
