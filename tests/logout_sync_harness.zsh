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

if perform_rsync "$WORKDIR/missing-source/" "$WORKDIR/destination/"; then
  print 'PASS sync: missing optional source was skipped cleanly'
else
  print 'FAIL sync: missing optional source reported a hard failure'
  failures=$((failures + 1))
fi

RSYNC_MODE='wait'
rsync() {
  case "$RSYNC_MODE" in
    wait)
      sleep 2
      ;;
    fail)
      print 'rsync: simulated transfer failure'
      return 23
      ;;
    permission)
      print 'rsync: Permission denied'
      return 23
      ;;
  esac
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

RSYNC_MODE='fail'
: > "$RSYNC_LOG"
SYNC_PERMISSION_DENIED=0
sleep 30 &
Notifier_Process=$!
perform_rsync "$WORKDIR/source/" "$WORKDIR/destination/"
rsync_failure_status=$?
kill -TERM "$Notifier_Process" 2>/dev/null || true
wait "$Notifier_Process" 2>/dev/null || true
Notifier_Process=""
if [ "$rsync_failure_status" -eq 23 ]; then
  print 'PASS sync: generic rsync failure status was preserved'
else
  print "FAIL sync: generic rsync failure returned $rsync_failure_status instead of 23"
  failures=$((failures + 1))
fi

RSYNC_MODE='permission'
: > "$RSYNC_LOG"
SYNC_PERMISSION_DENIED=0
sleep 30 &
Notifier_Process=$!
perform_rsync "$WORKDIR/source/" "$WORKDIR/destination/"
permission_status=$?
kill -TERM "$Notifier_Process" 2>/dev/null || true
wait "$Notifier_Process" 2>/dev/null || true
Notifier_Process=""
if [ "$permission_status" -eq 77 ] && [ "$SYNC_PERMISSION_DENIED" -eq 1 ]; then
  print 'PASS sync: rsync permission denial returned status 77'
else
  print "FAIL sync: permission denial returned $permission_status"
  failures=$((failures + 1))
fi

exec 3>&-

if [ "$failures" -gt 0 ]; then
  print "\n${failures} logout sync harness check(s) failed."
  exit 1
fi

print '\nAll logout sync harness checks passed.'
