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
exec 3>&-

failures=0
for folder in Pictures Documents Downloads Desktop; do
  expect_link "$LOCAL_HOME/$folder" "$REMOTE_HOME/$folder" || failures=$((failures + 1))
done

expect_content "$REMOTE_HOME/Documents/local-newer.txt" "newer local" || failures=$((failures + 1))
expect_content "$REMOTE_HOME/Documents/local-only.txt" "local only" || failures=$((failures + 1))
expect_content "$REMOTE_HOME/Pictures/remote-newer.txt" "newer remote" || failures=$((failures + 1))
expect_content "$REMOTE_HOME/Pictures/remote-only.txt" "remote only" || failures=$((failures + 1))

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
