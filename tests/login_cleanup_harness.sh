#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${1:-$(mktemp -d "${TMPDIR:-/tmp}/gms-login-test.XXXXXX")}"
USERS_DIR="$WORKDIR/Users"
LOG="$WORKDIR/LibrarySync.log"

CURRENT_USER="123active"
SIZE_THRESHOLD_KB=1
STAMP_REL="Library/Application Support/com.gvsd.LocalHomeLastLogin"

make_home() {
  local username="$1"
  mkdir -p "$USERS_DIR/$username/Library/Application Support/minecraft/saves"
  mkdir -p "$USERS_DIR/$username/Music/GarageBand"
  mkdir -p "$USERS_DIR/$username/Library/Caches"
}

stamp_home() {
  local username="$1"
  local days_old="$2"
  local stamp_path="$USERS_DIR/$username/$STAMP_REL"

  mkdir -p "$(dirname "$stamp_path")"
  touch "$stamp_path"
  touch -t "$(date -v-"$days_old"d "+%Y%m%d%H%M.%S")" "$stamp_path"
}

add_kb_file() {
  local path="$1"
  local kb="$2"

  mkdir -p "$(dirname "$path")"
  dd if=/dev/zero of="$path" bs=1024 count="$kb" >/dev/null 2>&1
}

expect_exists() {
  local path="$1"
  local label="$2"

  if [ -e "$path" ]; then
    printf 'PASS exists: %s\n' "$label"
  else
    printf 'FAIL missing: %s (%s)\n' "$label" "$path"
    return 1
  fi
}

expect_missing() {
  local path="$1"
  local label="$2"

  if [ ! -e "$path" ]; then
    printf 'PASS removed: %s\n' "$label"
  else
    printf 'FAIL still exists: %s (%s)\n' "$label" "$path"
    return 1
  fi
}

rm -rf "$WORKDIR"
mkdir -p "$USERS_DIR"
touch "$LOG"

make_home "Shared"
make_home "$CURRENT_USER"
make_home "100unstamped"
make_home "101fresh"
make_home "102stale"
make_home "103mediumlarge"
make_home "104mediumsmall"

stamp_home "101fresh" 3
stamp_home "102stale" 70
stamp_home "103mediumlarge" 20
stamp_home "104mediumsmall" 20

add_kb_file "$USERS_DIR/103mediumlarge/Music/GarageBand/big.dat" 4

GMS_CURRENT_USER="$CURRENT_USER"
GMS_USERS_BASE_DIR="$USERS_DIR"
GMS_SYNCLOG="$LOG"
GMS_LOCAL_CONTENT_SIZE_THRESHOLD_KB="$SIZE_THRESHOLD_KB"
export GMS_CURRENT_USER GMS_USERS_BASE_DIR GMS_SYNCLOG GMS_LOCAL_CONTENT_SIZE_THRESHOLD_KB

# Source functions without running the real login flow.
# shellcheck source=../login.sh
SANITIZED_LOGIN="$WORKDIR/login.sh"
LC_CTYPE=C sed $'1s/^\357\273\277//' "$REPO_ROOT/login.sh" > "$SANITIZED_LOGIN"
source "$SANITIZED_LOGIN"

chown() {
  return 0
}

set +e
DeleteOldLocalHomes
cleanup_status=$?
UpdateCurrentLoginStamp
stamp_status=$?
set -e

if [ "$cleanup_status" -ne 0 ]; then
  printf 'FAIL cleanup function exited with status %s\n' "$cleanup_status"
  exit 1
fi

if [ "$stamp_status" -ne 0 ]; then
  printf 'FAIL stamp function exited with status %s\n' "$stamp_status"
  exit 1
fi

printf '\nFake Users dir: %s\n' "$USERS_DIR"
printf 'Log file: %s\n\n' "$LOG"

failures=0

expect_exists "$USERS_DIR/Shared" "protected Shared home" || failures=$((failures + 1))
expect_exists "$USERS_DIR/$CURRENT_USER" "active user home" || failures=$((failures + 1))
expect_exists "$USERS_DIR/$CURRENT_USER/$STAMP_REL" "active user login stamp" || failures=$((failures + 1))
expect_missing "$USERS_DIR/100unstamped" "unstamped inactive home" || failures=$((failures + 1))
expect_exists "$USERS_DIR/101fresh" "fresh stamped home" || failures=$((failures + 1))
expect_missing "$USERS_DIR/102stale" "stale stamped home" || failures=$((failures + 1))
expect_exists "$USERS_DIR/103mediumlarge" "medium-age large-content home" || failures=$((failures + 1))
expect_missing "$USERS_DIR/103mediumlarge/Music/GarageBand" "large GarageBand content" || failures=$((failures + 1))
expect_exists "$USERS_DIR/104mediumsmall" "medium-age small-content home" || failures=$((failures + 1))
expect_exists "$USERS_DIR/104mediumsmall/Music/GarageBand" "small GarageBand content" || failures=$((failures + 1))

printf '\nRemaining fake homes:\n'
find "$USERS_DIR" -maxdepth 1 -mindepth 1 -type d -print | sort

printf '\nCleanup log:\n'
cat "$LOG"

if [ "$failures" -gt 0 ]; then
  printf '\n%s harness check(s) failed.\n' "$failures"
  exit 1
fi

printf '\nAll harness checks passed.\n'
