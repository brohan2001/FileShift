#!/bin/bash
# Real-browser end-to-end test.
# Downloads the same file 3 times with headless Firefox (throwaway profile, downloads
# go to a temp folder — never ~/Downloads) while fileshift-cli watches that folder.
# The test server streams slowly so Firefox's real .part behaviour is exercised.
# Needs: Firefox in /Applications, python3 (test server only — not used by FileShift itself).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIREFOX="${FIREFOX:-/Applications/Firefox.app/Contents/MacOS/firefox}"
[ -x "$FIREFOX" ] || { echo "SKIP: Firefox not found at $FIREFOX"; exit 0; }
command -v python3 >/dev/null || { echo "SKIP: python3 not available for the test server"; exit 0; }

cd "$ROOT"
swift build --product fileshift-cli >/dev/null
CLI="$(swift build --show-bin-path)/fileshift-cli"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fileshift-e2e.XXXXXX")"
DL="$TMP/dl"; PROFILE="$TMP/profile"; mkdir -p "$DL" "$PROFILE"
case "$DL" in "$HOME/Downloads"*) echo "refusing to use real Downloads"; exit 1;; esac
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; wait 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

cat > "$PROFILE/user.js" <<EOF
user_pref("browser.download.folderList", 2);
user_pref("browser.download.dir", "$DL");
user_pref("browser.download.useDownloadDir", true);
user_pref("browser.download.always_ask_before_handling_new_types", false);
user_pref("browser.helperApps.neverAsk.saveToDisk", "application/octet-stream,application/pdf");
user_pref("pdfjs.disabled", true);
user_pref("browser.download.manager.showWhenStarting", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("app.update.enabled", false);
EOF

# Slow test server: every request gets unique content, streamed in chunks over ~3 s.
cat > "$TMP/server.py" <<'EOF'
import hashlib, http.server, os, sys, time, uuid
served = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/report.pdf":
            self.send_response(404); self.end_headers(); return
        body = (f"%PDF-1.4 fake {uuid.uuid4()}\n".encode() + os.urandom(1024)) * 30
        with open(served, "a") as f: f.write(hashlib.sha256(body).hexdigest() + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", 'attachment; filename="report.pdf"')
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        step = len(body) // 15
        for i in range(0, len(body), step):
            self.wfile.write(body[i:i+step]); self.wfile.flush(); time.sleep(0.2)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
PORT=$(( 20000 + RANDOM % 20000 ))
python3 "$TMP/server.py" "$PORT" "$TMP/served.txt" & PIDS+=($!)

"$CLI" watch "$DL" --journal "$TMP/journal" --log "$TMP/fileshift.log" 2>"$TMP/watch.err" & PIDS+=($!)
sleep 1

saw_part=0
for i in 1 2 3; do
  echo "--- Firefox download #$i"
  "$FIREFOX" --headless --no-remote --profile "$PROFILE" "http://127.0.0.1:$PORT/report.pdf" >/dev/null 2>&1 &
  FF=$!
  # Wait for the download to finish (served count == i, no .part left, i real files present).
  for _ in $(seq 1 120); do
    sleep 0.5
    ls "$DL" | grep -q '\.part$' && saw_part=1
    served=$( [ -f "$TMP/served.txt" ] && wc -l < "$TMP/served.txt" | tr -d ' ' || echo 0)
    files=$(ls "$DL" | grep -v '\.part$' | grep -c . || true)
    if [ "$served" -ge "$i" ] && ! ls "$DL" | grep -q '\.part$' && [ "$files" -ge "$i" ]; then break; fi
  done
  sleep 6   # stability window (3 x 1 s) + processing
  kill "$FF" 2>/dev/null || true; wait "$FF" 2>/dev/null || true
  echo "    folder now: $(ls "$DL" | tr '\n' '|')"
done

echo "--- Results"
ls -la "$DL"
S=($(cat "$TMP/served.txt"))   # bash 3.2 compatible (no mapfile)
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
fail=0
check() { # name expected-sha label
  if [ -f "$DL/$1" ] && [ "$(sha "$DL/$1")" = "$2" ]; then echo "PASS  $1 = $3"
  else echo "FAIL  $1 should be $3"; fail=1; fi
}
check "report.pdf"    "${S[2]}" "download #3 (newest)"
check "report(1).pdf" "${S[1]}" "download #2"
check "report(2).pdf" "${S[0]}" "download #1 (oldest)"
[ "$(ls -A "$DL" | wc -l | tr -d ' ')" = "3" ] || { echo "FAIL  unexpected extra files"; fail=1; }
[ "$saw_part" = "1" ] && echo "INFO  observed Firefox .part files during download (slow-stream path exercised)"
echo "--- FileShift log"
cat "$TMP/fileshift.log"
[ "$fail" = "0" ] && echo "E2E PASSED" || { echo "E2E FAILED"; exit 1; }
