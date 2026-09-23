#!/bin/zsh

set -u
unsetopt BG_NICE

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR="${1:-$(mktemp -d "${TMPDIR:-/tmp}/gms-logout-sync.XXXXXX")}"
CURRENT_USER="$(id -un)"
USERS_DIR="$WORKDIR/Users"
USER_DIR="$USERS_DIR/$CURRENT_USER"
LOG="$WORKDIR/logout.log"

rm -rf "$WORKDIR"
mkdir -p "$USER_DIR" "$WORKDIR/source" "$WORKDIR/destination"

GMS_CURRENT_USER="$CURRENT_USER"
GMS_CONSOLE_USER="$CURRENT_USER"
GMS_USERS_BASE_DIR="$USERS_DIR"
GMS_USER_HOME="$USER_DIR"
export GMS_CURRENT_USER GMS_CONSOLE_USER GMS_USERS_BASE_DIR GMS_USER_HOME

source "$REPO_ROOT/save_logout.sh"
RSYNC_LOG="$LOG"
exec 3>/dev/null

failures=0

print 'source data' > "$WORKDIR/source/example.txt"
sleep 1
print 'newer destination data' > "$WORKDIR/destination/example.txt"
print 'destination only' > "$WORKDIR/destination/keep.txt"

sleep 30 &
Notifier_Process=$!
if perform_rsync "$WORKDIR/source/" "$WORKDIR/destination/"; then
  print 'PASS sync: successful transfer completed'
else
  print 'FAIL sync: successful transfer reported failure'
  failures=$((failures + 1))
fi
kill -TERM "$Notifier_Process" 2>/dev/null || true
wait "$Notifier_Process" 2>/dev/null || true
Notifier_Process=""

if [ "$(<"$WORKDIR/destination/example.txt")" = 'newer destination data' ]; then
  print 'PASS sync: newer destination file was preserved'
else
  print 'FAIL sync: newer destination file was overwritten'
  failures=$((failures + 1))
fi
if [ -f "$WORKDIR/destination/keep.txt" ]; then
  print 'PASS sync: destination-only file was preserved'
else
  print 'FAIL sync: destination-only file was removed'
  failures=$((failures + 1))
fi

rsync() {
  sleep 2
}

(sleep 0.2) &
Notifier_Process=$!
perform_rsync "$WORKDIR/source/" "$WORKDIR/destination/"
cancel_status=$?
if [ "$cancel_status" -eq 130 ]; then
  print 'PASS notifier: deliberate close cancels sync without permitting logout'
else
  print "FAIL notifier: deliberate close returned $cancel_status instead of 130"
  failures=$((failures + 1))
fi

(sleep 0.2; exit 9) &
Notifier_Process=$!
perform_rsync "$WORKDIR/source/" "$WORKDIR/destination/"
failure_status=$?
if [ "$failure_status" -eq 125 ]; then
  print 'PASS notifier: unexpected UI failure is distinguished from cancellation'
else
  print "FAIL notifier: UI failure returned $failure_status instead of 125"
  failures=$((failures + 1))
fi

exec 3>&-

if [ "$failures" -gt 0 ]; then
  print "\n${failures} logout sync harness check(s) failed."
  exit 1
fi

print '\nAll logout sync harness checks passed.'
