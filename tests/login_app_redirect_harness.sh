#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${1:-$(mktemp -d "${TMPDIR:-/tmp}/gms-app-redirect-test.XXXXXX")}" 
LOG="$WORKDIR/LibrarySync.log"
NOTIFIER_OUTPUT="$WORKDIR/notifier_commands.txt"

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
mkdir -p "$WORKDIR/source/iMovie" "$WORKDIR/target/iMovie"
touch "$LOG"

printf 'newer source\n' > "$WORKDIR/source/iMovie/source-newer.txt"
printf 'older target\n' > "$WORKDIR/target/iMovie/source-newer.txt"
touch -t 202605010000 "$WORKDIR/source/iMovie/source-newer.txt"
touch -t 202604010000 "$WORKDIR/target/iMovie/source-newer.txt"
printf 'older source\n' > "$WORKDIR/source/iMovie/target-newer.txt"
printf 'newer target\n' > "$WORKDIR/target/iMovie/target-newer.txt"
touch -t 202601010000 "$WORKDIR/source/iMovie/target-newer.txt"
touch -t 202606010000 "$WORKDIR/target/iMovie/target-newer.txt"
printf 'source only\n' > "$WORKDIR/source/iMovie/source-only.txt"
printf 'target only\n' > "$WORKDIR/target/iMovie/target-only.txt"

GMS_CURRENT_USER="$(id -un)"
GMS_SYNCLOG="$LOG"
export GMS_CURRENT_USER GMS_SYNCLOG

# shellcheck source=../login.sh
source "$REPO_ROOT/login.sh"

exec 3> "$NOTIFIER_OUTPUT"
RedirectAppFolderSafely "$WORKDIR/source/iMovie" "$WORKDIR/target/iMovie" "iMovie"
exec 3>&-

failures=0
if [ -L "$WORKDIR/source/iMovie" ] && [ "$(readlink "$WORKDIR/source/iMovie")" = "$WORKDIR/target/iMovie" ]; then
  printf 'PASS link: iMovie redirection created\n'
else
  printf 'FAIL link: iMovie redirection missing or incorrect\n'
  failures=$((failures + 1))
fi

expect_content "$WORKDIR/target/iMovie/source-newer.txt" "newer source" || failures=$((failures + 1))
expect_content "$WORKDIR/target/iMovie/target-newer.txt" "newer target" || failures=$((failures + 1))
expect_content "$WORKDIR/target/iMovie/source-only.txt" "source only" || failures=$((failures + 1))
expect_content "$WORKDIR/target/iMovie/target-only.txt" "target only" || failures=$((failures + 1))

if [ ! -e "$WORKDIR/source/.gvsd_app_redirect_staging" ]; then
  printf 'PASS cleanup: application staging directory removed\n'
else
  printf 'FAIL cleanup: application staging directory remains\n'
  failures=$((failures + 1))
fi

# A later login must retain an already-correct link and recover staging data
# left by an interrupted earlier merge.
mkdir -p "$WORKDIR/source/.gvsd_app_redirect_staging/iMovie.ABC123/iMovie"
printf 'recovered data\n' > "$WORKDIR/source/.gvsd_app_redirect_staging/iMovie.ABC123/iMovie/recovered.txt"
exec 3>> "$NOTIFIER_OUTPUT"
RedirectAppFolderSafely "$WORKDIR/source/iMovie" "$WORKDIR/target/iMovie" "iMovie"
exec 3>&-

if grep -q 'symlink already correct' "$LOG"; then
  printf 'PASS idempotence: correct symlink was retained\n'
else
  printf 'FAIL idempotence: correct symlink was not recognized\n'
  failures=$((failures + 1))
fi

expect_content "$WORKDIR/target/iMovie/recovered.txt" "recovered data" || failures=$((failures + 1))
if [ ! -e "$WORKDIR/source/.gvsd_app_redirect_staging" ]; then
  printf 'PASS recovery: retained application data merged and staging removed\n'
else
  printf 'FAIL recovery: retained application staging directory remains\n'
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  printf '\n%s application redirection harness check(s) failed.\n' "$failures"
  exit 1
fi

printf '\nAll application redirection harness checks passed.\n'
