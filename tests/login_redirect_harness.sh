#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${1:-$(mktemp -d "${TMPDIR:-/tmp}/gms-redirect-test.XXXXXX")}"
USERS_DIR="$WORKDIR/Users"
REMOTE_ROOT="$WORKDIR/Remote"
CURRENT_USER="123redirect"
LOCAL_HOME="$USERS_DIR/$CURRENT_USER"
REMOTE_HOME="$REMOTE_ROOT/$CURRENT_USER"
LOG="$WORKDIR/LibrarySync.log"
NOTIFIER_OUTPUT="$WORKDIR/notifier_commands.txt"

expect_link() {
  local path="$1"
  local target="$2"

  if [ -L "$path" ] && [ "$(readlink "$path")" = "$target" ]; then
    printf 'PASS link: %s -> %s\n' "$path" "$target"
  else
    printf 'FAIL link: %s does not point to %s\n' "$path" "$target"
    return 1
  fi
}

expect_content() {
  local path="$1"
  local expected="$2"

  if [ -f "$path" ] && [ "$(cat "$path")" = "$expected" ]; then
    printf 'PASS content: %s\n' "$path"
  else
    printf 'FAIL content: %s\n' "$path"
    return 1
  fi
}

rm -rf "$WORKDIR"
mkdir -p "$LOCAL_HOME/Documents" "$LOCAL_HOME/Pictures" "$LOCAL_HOME/Downloads"
mkdir -p "$REMOTE_HOME/Documents" "$REMOTE_HOME/Pictures" "$REMOTE_HOME/Downloads" "$REMOTE_HOME/Desktop"
touch "$LOG"

printf 'newer local\n' > "$LOCAL_HOME/Documents/local-newer.txt"
printf 'older remote\n' > "$REMOTE_HOME/Documents/local-newer.txt"
touch -t 202603010000 "$LOCAL_HOME/Documents/local-newer.txt"
touch -t 202602010000 "$REMOTE_HOME/Documents/local-newer.txt"
printf 'local only\n' > "$LOCAL_HOME/Documents/local-only.txt"

printf 'older local\n' > "$LOCAL_HOME/Pictures/remote-newer.txt"
printf 'newer remote\n' > "$REMOTE_HOME/Pictures/remote-newer.txt"
touch -t 202601010000 "$LOCAL_HOME/Pictures/remote-newer.txt"
touch -t 202604010000 "$REMOTE_HOME/Pictures/remote-newer.txt"
printf 'remote only\n' > "$REMOTE_HOME/Pictures/remote-only.txt"

ln -s "$REMOTE_HOME/Desktop" "$LOCAL_HOME/Desktop"

# A previous login may have created the symlink but failed before merging its
# retained local data. Verify a later login retries that merge automatically.
mkdir -p "$LOCAL_HOME/.gvsd_redirect_staging/Desktop.ABC123/Desktop"
printf 'retained only\n' > "$LOCAL_HOME/.gvsd_redirect_staging/Desktop.ABC123/Desktop/retained-only.txt"
printf 'newer retained\n' > "$LOCAL_HOME/.gvsd_redirect_staging/Desktop.ABC123/Desktop/retained-newer.txt"
printf 'older remote\n' > "$REMOTE_HOME/Desktop/retained-newer.txt"
touch -t 202605010000 "$LOCAL_HOME/.gvsd_redirect_staging/Desktop.ABC123/Desktop/retained-newer.txt"
touch -t 202604010000 "$REMOTE_HOME/Desktop/retained-newer.txt"
printf 'older retained\n' > "$LOCAL_HOME/.gvsd_redirect_staging/Desktop.ABC123/Desktop/remote-stays-newer.txt"
printf 'newer remote\n' > "$REMOTE_HOME/Desktop/remote-stays-newer.txt"
touch -t 202601010000 "$LOCAL_HOME/.gvsd_redirect_staging/Desktop.ABC123/Desktop/remote-stays-newer.txt"
touch -t 202606010000 "$REMOTE_HOME/Desktop/remote-stays-newer.txt"

GMS_CURRENT_USER="$CURRENT_USER"
GMS_USERS_BASE_DIR="$USERS_DIR"
GMS_SYNCLOG="$LOG"
export GMS_CURRENT_USER GMS_USERS_BASE_DIR GMS_SYNCLOG

SANITIZED_LOGIN="$WORKDIR/login.sh"
LC_CTYPE=C sed $'1s/^\357\273\277//' "$REPO_ROOT/login.sh" > "$SANITIZED_LOGIN"
# shellcheck source=../login.sh
source "$SANITIZED_LOGIN"

MOUNT_MODE="multiple"
mount() {
  printf 'server:/Student on %s (smbfs, mounted by %s)\n' "$REMOTE_ROOT" "$CURRENT_USER"
  if [ "$MOUNT_MODE" = "multiple" ]; then
    printf 'server:/Student-Archive on %s (smbfs, mounted by %s)\n' "$WORKDIR/OtherRemote" "$CURRENT_USER"
  fi
}

GMS_MOUNT_RETRIES=1
export GMS_MOUNT_RETRIES
if CheckFolderPath "Student"; then
  printf 'FAIL mount selection: multiple matching mounts were accepted\n'
  exit 1
else
  printf 'PASS mount selection: multiple matching mounts were rejected\n'
fi

MOUNT_MODE="unique"
if CheckFolderPath "Student" && [ "$MYHOMEDIR" = "$REMOTE_HOME" ]; then
  printf 'PASS mount selection: unique network home detected\n'
else
  printf 'FAIL mount selection: unique network home was not detected\n'
  exit 1
fi

exec 3> "$NOTIFIER_OUTPUT"
RedirectIfADAccount
WriteRedirectState
exec 3>&-

failures=0
for folder in Pictures Documents Downloads Desktop; do
  expect_link "$LOCAL_HOME/$folder" "$REMOTE_HOME/$folder" || failures=$((failures + 1))
done

expect_content "$REMOTE_HOME/Documents/local-newer.txt" "newer local" || failures=$((failures + 1))
expect_content "$REMOTE_HOME/Documents/local-only.txt" "local only" || failures=$((failures + 1))
expect_content "$REMOTE_HOME/Pictures/remote-newer.txt" "newer remote" || failures=$((failures + 1))
expect_content "$REMOTE_HOME/Pictures/remote-only.txt" "remote only" || failures=$((failures + 1))
expect_content "$REMOTE_HOME/Desktop/retained-only.txt" "retained only" || failures=$((failures + 1))
expect_content "$REMOTE_HOME/Desktop/retained-newer.txt" "newer retained" || failures=$((failures + 1))
expect_content "$REMOTE_HOME/Desktop/remote-stays-newer.txt" "newer remote" || failures=$((failures + 1))

redirect_state="$LOCAL_HOME/$REDIRECT_STATE_REL"
if [ -f "$redirect_state" ] && grep -Fq "network_home=$REMOTE_HOME" "$redirect_state"; then
  printf 'PASS state: verified redirection state recorded\n'
else
  printf 'FAIL state: verified redirection state missing or incorrect\n'
  failures=$((failures + 1))
fi

# State must never be recorded if even one managed folder is no longer the
# exact symlink established by login.
ClearRedirectState
rm "$LOCAL_HOME/Downloads"
mkdir "$LOCAL_HOME/Downloads"
if WriteRedirectState; then
  printf 'FAIL state: local replacement folder was accepted as verified redirection\n'
  failures=$((failures + 1))
else
  printf 'PASS state: local replacement folder prevented state creation\n'
fi
if [ -e "$redirect_state" ]; then
  printf 'FAIL state: failed verification left a state file behind\n'
  failures=$((failures + 1))
else
  printf 'PASS state: failed verification left no state file\n'
fi
rmdir "$LOCAL_HOME/Downloads"
ln -s "$REMOTE_HOME/Downloads" "$LOCAL_HOME/Downloads"
WriteRedirectState

# Unexpected retained staging structures are preserved for investigation and
# cause redirection verification to report an incomplete recovery.
mkdir -p "$LOCAL_HOME/.gvsd_redirect_staging/Documents.BAD/Documents"
printf 'do not discard\n' > "$LOCAL_HOME/.gvsd_redirect_staging/Documents.BAD/Documents/retained.txt"
if RedirectIfADAccount; then
  printf 'FAIL staging: suspicious retained staging area was accepted\n'
  failures=$((failures + 1))
elif [ -f "$LOCAL_HOME/.gvsd_redirect_staging/Documents.BAD/Documents/retained.txt" ]; then
  printf 'PASS staging: suspicious retained data was preserved and reported\n'
else
  printf 'FAIL staging: suspicious retained data was removed\n'
  failures=$((failures + 1))
fi
rm -rf "$LOCAL_HOME/.gvsd_redirect_staging/Documents.BAD"
rmdir "$LOCAL_HOME/.gvsd_redirect_staging" 2>/dev/null || true

if [ ! -e "$LOCAL_HOME/.gvsd_redirect_staging" ]; then
  printf 'PASS cleanup: staging directory removed\n'
else
  printf 'FAIL cleanup: staging directory remains at %s\n' "$LOCAL_HOME/.gvsd_redirect_staging"
  failures=$((failures + 1))
fi

if grep -q '^/bottom_message Syncing: ' "$NOTIFIER_OUTPUT"; then
  printf 'PASS notifier: filename progress commands emitted\n'
else
  printf 'FAIL notifier: no filename progress commands found\n'
  failures=$((failures + 1))
fi

printf '\nRedirection log:\n'
cat "$LOG"

if [ "$failures" -gt 0 ]; then
  printf '\n%s redirection harness check(s) failed.\n' "$failures"
  exit 1
fi

printf '\nAll redirection harness checks passed.\n'
