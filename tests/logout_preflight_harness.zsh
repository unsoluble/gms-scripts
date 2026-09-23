#!/bin/zsh

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR="${1:-$(mktemp -d "${TMPDIR:-/tmp}/gms-logout-preflight.XXXXXX")}" 
CURRENT_USER="$(id -un)"
USERS_DIR="$WORKDIR/Users"
USER_DIR="$USERS_DIR/$CURRENT_USER"
NETWORK_HOME="$WORKDIR/Network/$CURRENT_USER"
LOG="$WORKDIR/logout.log"
STATE_REL="Library/Application Support/com.gvsd.RedirectState"

rm -rf "$WORKDIR"
mkdir -p "$USER_DIR/Library/Application Support" "$NETWORK_HOME"
for folder in Desktop Documents Downloads Pictures; do
  mkdir -p "$NETWORK_HOME/$folder"
  ln -s "$NETWORK_HOME/$folder" "$USER_DIR/$folder"
done

GMS_CURRENT_USER="$CURRENT_USER"
GMS_CONSOLE_USER="$CURRENT_USER"
GMS_USERS_BASE_DIR="$USERS_DIR"
GMS_USER_HOME="$USER_DIR"
export GMS_CURRENT_USER GMS_CONSOLE_USER GMS_USERS_BASE_DIR GMS_USER_HOME

source "$REPO_ROOT/save_logout.sh"
RSYNC_LOG="$LOG"

failures=0
write_state() {
  mkdir -p "$(dirname "$USER_DIR/$STATE_REL")"
  printf 'version=1\nnetwork_home=%s\nverified_at=1\n' "$1" > "$USER_DIR/$STATE_REL"
}

write_state "$NETWORK_HOME"
if validate_logout_user && validate_managed_redirections; then
  print 'PASS preflight: valid managed redirections accepted'
else
  print 'FAIL preflight: valid managed redirections rejected'
  failures=$((failures + 1))
fi

if acquire_logout_workflow_lock; then
  print 'PASS lock: logout workflow lock acquired'
else
  print 'FAIL lock: logout workflow lock could not be acquired'
  failures=$((failures + 1))
fi
if acquire_logout_workflow_lock; then
  print 'FAIL lock: duplicate logout workflow lock acquired'
  failures=$((failures + 1))
else
  print 'PASS lock: duplicate logout workflow rejected'
fi
release_logout_workflow_lock

mkdir -p "${WORKFLOW_LOCK_PATH}"
print '999999' > "${WORKFLOW_LOCK_PATH}/pid"
if acquire_logout_workflow_lock; then
  print 'PASS lock: stale logout workflow lock replaced'
  release_logout_workflow_lock
else
  print 'FAIL lock: stale logout workflow lock not replaced'
  failures=$((failures + 1))
fi

rm -f "$USER_DIR/Documents"
mkdir "$USER_DIR/Documents"
if validate_managed_redirections; then
  print 'FAIL preflight: local Documents folder accepted'
  failures=$((failures + 1))
else
  print 'PASS preflight: local Documents folder rejected'
fi
rmdir "$USER_DIR/Documents"
ln -s "$NETWORK_HOME/Documents" "$USER_DIR/Documents"

write_state "$WORKDIR/WrongNetwork/$CURRENT_USER"
if validate_managed_redirections; then
  print 'FAIL preflight: stale network-home state accepted'
  failures=$((failures + 1))
else
  print 'PASS preflight: stale network-home state rejected'
fi

rm -f "$USER_DIR/$STATE_REL"
if validate_managed_redirections; then
  print 'FAIL preflight: missing state accepted'
  failures=$((failures + 1))
else
  print 'PASS preflight: missing state rejected'
fi

GMS_CONSOLE_USER="someone-else"
if validate_logout_user; then
  print 'FAIL validation: mismatched console user accepted'
  failures=$((failures + 1))
else
  print 'PASS validation: mismatched console user rejected'
fi

if [ "$failures" -gt 0 ]; then
  print "\n${failures} logout preflight harness check(s) failed."
  exit 1
fi

print '\nAll logout preflight harness checks passed.'
