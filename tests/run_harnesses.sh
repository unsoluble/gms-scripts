#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELLCHECK_BIN="${SHELLCHECK_BIN:-$(command -v shellcheck || true)}"

cd "$REPO_ROOT"

printf '== Static checks ==\n'
bash -n login.sh
zsh -n save_logout.sh
for test_file in tests/*.sh; do
  bash -n "$test_file"
done
for test_file in tests/*.zsh; do
  zsh -o NO_BG_NICE -n "$test_file"
done
if [ -n "$SHELLCHECK_BIN" ]; then
  "$SHELLCHECK_BIN" -x login.sh
  "$SHELLCHECK_BIN" -x -e SC1090,SC1091 tests/*.sh
else
  printf 'WARN shellcheck: executable not found; lint check skipped\n'
fi
git diff --check
printf 'PASS static checks\n'

run_harness() {
  local test_file="$1"
  local output_file=""

  printf '\n== %s ==\n' "$test_file"
  if [ "${HARNESS_VERBOSE:-0}" = "1" ]; then
    "$test_file"
    return
  fi

  output_file=$(mktemp "${TMPDIR:-/tmp}/gms-harness-output.XXXXXX")
  if "$test_file" >"$output_file" 2>&1; then
    tail -n 1 "$output_file"
    rm -f "$output_file"
  else
    cat "$output_file"
    rm -f "$output_file"
    return 1
  fi
}

for test_file in tests/*_harness.sh; do
  run_harness "$test_file"
done

for test_file in tests/*_harness.zsh; do
  run_harness "$test_file"
done

printf '\nAll static checks and harnesses passed.\n'
