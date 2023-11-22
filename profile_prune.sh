#!/bin/bash

# Define the age threshold (in days)
AGE_THRESHOLD=30

# Loop through each directory in /Users
for dir in /Users/*; do
  # Skip if it's not a directory
  [ -d "$dir" ] || continue

  # Extract username from directory path
  username=$(basename "$dir")

  # Skip system accounts
  case "$username" in
    "Shared"|"Guest"|".localized"|"admin"|"helpdesk")
      continue
      ;;
  esac

  # Check if the directory was modified more than a month ago
  if [ $(find "$dir" -maxdepth 0 -type d -not -mtime -$AGE_THRESHOLD | wc -l) -gt 0 ]; then
    WriteToLogs "Deleting user home directory for $username, not modified in last $AGE_THRESHOLD days."
    rm -rf "$dir"
  fi
done