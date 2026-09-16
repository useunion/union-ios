#!/bin/bash
#
# End-to-end crash check: one process really dies, the next one uploads what it left behind.
#
# `swift test` cannot cover this seam — a test runner that takes SIGSEGV reports nothing, which is why
# `CrashTests` goes through `union_crash_capture_live` instead. So this runs the real thing: install
# the handler, dereference null, let the process die, then start a *second* process that finds the
# record on disk and POSTs it to a local stand-in for /v1/crash.
#
# Run it before a release, and after any change to Sources/UnionCrashCore or Sources/Union/Crash.
#
#   Scripts/crash-e2e.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
PORT="${UNION_CRASH_E2E_PORT:-8923}"
BATCH="$WORK/batch.json"
SERVER_PID=""

cleanup() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

cd "$ROOT"

echo "==> building Union (debug)"
swift build > "$WORK/build.log" 2>&1 || { cat "$WORK/build.log"; fail "swift build"; }

# The handler is C and the reporter's entry points are internal, so the harness is compiled against
# the debug objects with -enable-testing rather than linked as a package product.
cat > "$WORK/module.modulemap" <<MAP
module UnionCrashCore {
    umbrella "$ROOT/Sources/UnionCrashCore/include"
    export *
}
MAP

echo "==> building the harness"
swiftc -o "$WORK/harness" Scripts/crash-e2e/harness.swift \
    -enable-testing \
    -I .build/debug/Modules \
    -I Sources/UnionCrashCore/include \
    -Xcc -fmodule-map-file="$WORK/module.modulemap" \
    .build/debug/Union.build/*.o \
    .build/debug/UnionCrashCore.build/*.o \
    -framework Foundation > "$WORK/harness-build.log" 2>&1 \
    || { cat "$WORK/harness-build.log"; fail "harness build"; }

python3 Scripts/crash-e2e/ingest.py "$BATCH" "$PORT" 202 > "$WORK/ingest.log" 2>&1 &
SERVER_PID=$!
disown "$SERVER_PID" 2>/dev/null || true
sleep 1
kill -0 "$SERVER_PID" 2>/dev/null || { cat "$WORK/ingest.log"; fail "ingest server did not start (port $PORT busy?)"; }

STORE="$WORK/store"
mkdir -p "$STORE"
ENDPOINT="http://127.0.0.1:$PORT/v1/crash"

echo "==> crashing for real"
# The dying process hands the signal back to whoever had it, so macOS ReportCrash takes its own
# minutes-long look at the corpse. We only care that the handler wrote before the re-raise, so the
# harness is backgrounded and killed once the record is on disk.
"$WORK/harness" crash "$STORE" "$ENDPOINT" > "$WORK/crash.log" 2>&1 &
CRASH_PID=$!
for _ in $(seq 1 100); do
    [ -s "$STORE"/*.ucr ] 2>/dev/null && break
    sleep 0.2
done
kill -9 "$CRASH_PID" 2>/dev/null || true
wait "$CRASH_PID" 2>/dev/null || true

grep -q "handlers installed" "$WORK/crash.log" || { cat "$WORK/crash.log"; fail "handlers were never installed"; }
grep -q "unreachable" "$WORK/crash.log" && fail "the process survived the null dereference"
ls "$STORE"/*.ucr > /dev/null 2>&1 || { cat "$WORK/crash.log"; fail "no record was written — the handler did not fire"; }
[ -s "$STORE"/*.ucr ] || fail "the record is empty, which means 'no crash'"
echo "    record written: $(basename "$(ls "$STORE"/*.ucr)") ($(wc -c < "$STORE"/*.ucr | tr -d ' ') bytes)"

# A crash dropped on a flaky connection is a crash the developer never learns about, so the offline
# attempt has to leave the file exactly where it was.
echo "==> next launch, no network: the report must survive"
"$WORK/harness" report "$STORE" "http://127.0.0.1:9/v1/crash" > "$WORK/offline.log" 2>&1 || true
grep -q "reports still on disk = 1" "$WORK/offline.log" \
    || { cat "$WORK/offline.log"; fail "a failed upload deleted the report"; }

echo "==> next launch, ingest up: the report must be sent and only then deleted"
"$WORK/harness" report "$STORE" "$ENDPOINT" > "$WORK/online.log" 2>&1 \
    || { cat "$WORK/online.log"; fail "the report phase exited non-zero"; }
grep -q "reports still on disk = 0" "$WORK/online.log" \
    || { cat "$WORK/online.log"; fail "the report was accepted but not cleared"; }
grep -q "ingest:" "$WORK/ingest.log" || { cat "$WORK/ingest.log"; fail "nothing reached the ingest"; }
sed 's/^/    /' "$WORK/ingest.log"

echo "==> checking what the server received"
[ -f "$BATCH" ] || fail "the ingest saved no batch"
python3 Scripts/crash-e2e/assert.py "$BATCH" EXC_BAD_ACCESS || fail "the batch is not what the contract expects"

echo "PASS: crash -> disk -> next launch -> gzipped POST /v1/crash -> accepted -> cleared"
