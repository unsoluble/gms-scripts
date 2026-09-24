#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${1:-$(mktemp -d "${TMPDIR:-/tmp}/gms-init-test.XXXXXX")}" 
CURRENT_USER="$(id -un)"
USERS_DIR="$WORKDIR/Users"
LOG="$WORKDIR/Logs/LibrarySync.log"

rm -rf "$WORKDIR"
mkdir -p "$USERS_DIR/$CURRENT_USER"

GMS_CURRENT_USER="$CURRENT_USER"
GMS_CONSOLE_USER="$CURRENT_USER"
GMS_USERS_BASE_DIR="$USERS_DIR"
GMS_SYNCLOG="$LOG"
export GMS_CURRENT_USER GMS_CONSOLE_USER GMS_USERS_BASE_DIR GMS_SYNCLOG

# shellcheck source=../login.sh
source "$REPO_ROOT/login.sh"

failures=0
InitializeLoginScript
runtime_dir="$PIPE_DIR"

if ValidateCurrentUser; then
  printf 'PASS validation: active console user accepted\n'
else
  printf 'FAIL validation: active console user rejected\n'
  failures=$((failures + 1))
fi

if AcquireLoginWorkflowLock; then
  printf 'PASS lock: login workflow lock acquired\n'
else
  printf 'FAIL lock: login workflow lock could not be acquired\n'
  failures=$((failures + 1))
fi
if AcquireLoginWorkflowLock; then
  printf 'FAIL lock: duplicate login workflow lock acquired\n'
  failures=$((failures + 1))
else
  printf 'PASS lock: overlapping workflow rejected\n'
fi

ReleaseLoginWorkflowLock
WORKFLOW_LOCK_PATH="$USERS_DIR/$CURRENT_USER/Library/Application Support/.gvsd_workflow_lock"
mkdir -p "$WORKFLOW_LOCK_PATH"
printf '999999\n' > "$WORKFLOW_LOCK_PATH/pid"
if AcquireLoginWorkflowLock; then
  printf 'PASS lock: stale workflow lock replaced\n'
else
  printf 'FAIL lock: stale workflow lock was not replaced\n'
  failures=$((failures + 1))
fi
ReleaseLoginWorkflowLock

unsafe_lock_target="$WORKDIR/unsafe-lock-target"
mkdir -p "$unsafe_lock_target"
WORKFLOW_LOCK_PATH="$USERS_DIR/$CURRENT_USER/Library/Application Support/.gvsd_workflow_lock"
ln -s "$unsafe_lock_target" "$WORKFLOW_LOCK_PATH"
if AcquireLoginWorkflowLock; then
  printf 'FAIL lock: symlinked workflow lock was accepted\n'
  ReleaseLoginWorkflowLock
  failures=$((failures + 1))
else
  printf 'PASS lock: symlinked workflow lock rejected\n'
fi
rm "$WORKFLOW_LOCK_PATH"

if [ -p "$PIPE_PATH" ] && [[ "$PIPE_PATH" == /tmp/gvsd-login.*/notifier.pipe ]]; then
  printf 'PASS fifo: unique secure runtime path created\n'
else
  printf 'FAIL fifo: secure runtime path missing or unexpected (%s)\n' "$PIPE_PATH"
  failures=$((failures + 1))
fi

log_mode=$(stat -f '%Lp' "$LOG")
if [ "$log_mode" = "644" ] && [ ! -L "$LOG" ]; then
  printf 'PASS log: regular file created with mode 644\n'
else
  printf 'FAIL log: mode=%s symlink=%s\n' "$log_mode" "$([ -L "$LOG" ] && echo yes || echo no)"
  failures=$((failures + 1))
fi

GMS_CONSOLE_USER="someone-else"
if ValidateCurrentUser; then
  printf 'FAIL validation: mismatched console user accepted\n'
  failures=$((failures + 1))
else
  printf 'PASS validation: mismatched console user rejected\n'
fi

CleanupLoginRuntime
ReleaseLoginWorkflowLock
trap - EXIT HUP INT TERM
if [ ! -e "$runtime_dir" ]; then
  printf 'PASS cleanup: runtime FIFO and directory removed\n'
else
  printf 'FAIL cleanup: runtime directory remains at %s\n' "$runtime_dir"
  failures=$((failures + 1))
fi

protected_target="$WORKDIR/protected-target"
printf 'do not modify\n' > "$protected_target"
chmod 600 "$protected_target"
SYNCLOG="$WORKDIR/Logs/Symlinked.log"
ln -s "$protected_target" "$SYNCLOG"
if InitializeLoginScript; then
  printf 'FAIL log: symlinked log path was accepted\n'
  CleanupLoginRuntime
  trap - EXIT HUP INT TERM
  failures=$((failures + 1))
elif [ "$(stat -f '%Lp' "$protected_target")" = "600" ]; then
  printf 'PASS log: symlinked path rejected without changing target\n'
else
  printf 'FAIL log: protected symlink target permissions changed\n'
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  printf '\n%s initialization harness check(s) failed.\n' "$failures"
  exit 1
fi

printf '\nAll initialization harness checks passed.\n'
