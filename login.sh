#!/bin/bash

####################################################################################
# Script to handle folder redirections and permissions for student & staff logins. #
####################################################################################

# Set global variables.
SCRIPT_VERSION="2026-09-23-1214"
CurrentUSER="${GMS_CURRENT_USER:-$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /Loginwindow/ { print $3 }' )}"
SYNCLOG="${GMS_SYNCLOG:-/Library/Logs/GVSD/LibrarySync.log}"
USERS_BASE_DIR="${GMS_USERS_BASE_DIR:-/Users}"
# Age threshold for local home cleanup (days)
AGE_THRESHOLD=15
# Age threshold for local home deletion (days)
OLD_AGE_THRESHOLD=60
# Size threshold for local content cleanup (KB)
LOCAL_CONTENT_SIZE_THRESHOLD_KB="${GMS_LOCAL_CONTENT_SIZE_THRESHOLD_KB:-512000}"
# Local marker used to record the last completed login for cleanup age checks.
LOCAL_LOGIN_STAMP_REL="Library/Application Support/com.gvsd.LocalHomeLastLogin"
# Local state proving that the managed home-folder links were verified at login.
REDIRECT_STATE_REL="Library/Application Support/com.gvsd.RedirectState"

# Notifier UI paths.
APP_PATH="/Applications/IBM Notifier.app/Contents/MacOS/IBM Notifier"

# Variables for the progress dialog.
PROG_BAR_TITLE="Logging In"
PROG_TITLE="Syncing your files! Your stuff will be ready when this finishes."
PROG_ACCESSORY_TYPE="progressbar"
PROG_ACCESSORY_PAYLOAD="/percent indeterminate \
                        /user_interruption_allowed false \
                        /exit_on_completion true"
PROG_TIMEOUT_SECONDS=300

# Runtime paths and process IDs are populated during secure initialization.
PIPE_DIR=""
PIPE_PATH=""
Notifier_Process=""

# Declare a global for the function logging routines.
FUNC_START_TIME=""

#############
# FUNCTIONS #
#############

# Logs to both the console and the global logfile.
WriteToLogs() {
  local message="$1"
  local now=""
  now=$(date "+%Y-%m-%d %T")
  echo "$now - $message" >> "$SYNCLOG"
  echo "$now - $message"
}

# Keep progress messages readable while retaining useful path context.
ShortenPathForDisplay() {
  local path="${1%/}"
  local filename="${path##*/}"
  local parent="${path%/*}"
  local display="$filename"

  if [ "$parent" != "$path" ]; then
    display="${parent##*/}/$filename"
  fi

  if [ "${#display}" -gt 72 ]; then
    display="...${display: -69}"
  fi

  printf '%s' "$display"
}

NotifyBottomMessage() {
  local message="${1//$'\n'/ }"

  if [ -e /dev/fd/3 ]; then
    printf '/bottom_message %s\n' "$message" >&3 2>/dev/null || true
  fi
}

# Run rsync while preserving its exit status and streaming filenames to Notifier.
RunRsyncWithNotifier() {
  local source="$1"
  local destination="$2"
  local line=""
  local relative_path=""
  local short_path=""

  rsync -avzu --out-format='RSYNC_FILE:%n' "$source" "$destination" 2>&1 |
    while IFS= read -r line; do
      WriteToLogs "rsync: $line"
      case "$line" in
        RSYNC_FILE:*)
          relative_path="${line#RSYNC_FILE:}"
          short_path=$(ShortenPathForDisplay "$relative_path")
          NotifyBottomMessage "Syncing: $short_path"
          ;;
      esac
    done

  return "${PIPESTATUS[0]}"
}

InitializeLoginScript() {
  local log_dir=""
  local log_name=""
  local archive_path=""

  log_dir=$(dirname "$SYNCLOG")
  log_name=$(basename "$SYNCLOG")

  if [ -L "$log_dir" ]; then
    echo "Refusing to use symlinked login log directory $log_dir." >&2
    return 1
  fi
  if [ ! -d "$log_dir" ]; then
    if ! mkdir -p "$log_dir" || ! chmod 755 "$log_dir"; then
      echo "Unable to create secure login log directory $log_dir." >&2
      return 1
    fi
  fi

  if [ -L "$SYNCLOG" ]; then
    echo "Refusing to use symlinked login log $SYNCLOG." >&2
    return 1
  fi

  # Rotate the logs.
  if [ -f "$SYNCLOG" ]; then
    archive_path="$log_dir/${log_name%.log}-$(date +%Y-%m-%d_%H-%M-%S)-$$.log"
    if ! mv "$SYNCLOG" "$archive_path"; then
      echo "Unable to rotate login log $SYNCLOG." >&2
      return 1
    fi
  fi
  # Delete archived logs older than 2 days.
  find "$log_dir" -maxdepth 1 -type f -name "${log_name%.log}-*.log" -mtime +2 -exec rm {} \;

  if ! (umask 022 && : > "$SYNCLOG") || ! chmod 644 "$SYNCLOG"; then
    echo "Unable to create secure login log $SYNCLOG." >&2
    return 1
  fi

  PIPE_DIR=$(mktemp -d "/tmp/gvsd-login.XXXXXX") || return 1
  if ! chmod 700 "$PIPE_DIR"; then
    CleanupLoginRuntime
    return 1
  fi
  PIPE_PATH="$PIPE_DIR/notifier.pipe"
  if ! mkfifo "$PIPE_PATH" || ! exec 3<> "$PIPE_PATH"; then
    CleanupLoginRuntime
    return 1
  fi

  trap CleanupLoginRuntime EXIT
  trap 'exit 1' HUP INT TERM
  return 0
}

CleanupLoginRuntime() {
  exec 3>&- 2>/dev/null || true

  if [ -n "$Notifier_Process" ] && kill -0 "$Notifier_Process" 2>/dev/null; then
    kill -TERM "$Notifier_Process" 2>/dev/null || true
    wait "$Notifier_Process" 2>/dev/null || true
  fi
  Notifier_Process=""

  if [ -n "$PIPE_PATH" ]; then
    rm -f "$PIPE_PATH"
  fi
  if [ -n "$PIPE_DIR" ]; then
    rmdir "$PIPE_DIR" 2>/dev/null || true
  fi
  PIPE_PATH=""
  PIPE_DIR=""
}

ValidateCurrentUser() {
  local console_user="${GMS_CONSOLE_USER:-}"
  local local_home=""

  if [ -z "$console_user" ]; then
    console_user=$(stat -f%Su /dev/console 2>/dev/null)
  fi

  case "$CurrentUSER" in
    ""|loginwindow|root|*/*)
      WriteToLogs "ERROR: Refusing to run for invalid console user '$CurrentUSER'."
      return 1
      ;;
  esac

  if [ -z "$console_user" ] || [ "$console_user" != "$CurrentUSER" ]; then
    WriteToLogs "ERROR: Captured user '$CurrentUSER' does not match active console user '$console_user'."
    return 1
  fi

  local_home="$USERS_BASE_DIR/$CurrentUSER"
  if [ ! -d "$local_home" ] || [ -L "$local_home" ]; then
    WriteToLogs "ERROR: Expected local home $local_home is missing or is a symlink."
    return 1
  fi

  WriteToLogs "Validated active console user $CurrentUSER with local home $local_home."
  return 0
}

# Log the start of a function, and capture the time for its duration.
StartFunctionLog() {
  FUNC_START_TIME=$(date +%s)
  WriteToLogs "### Started ${FUNCNAME[1]} function" # FUNCNAME[1] is the name of the calling function
  NotifyBottomMessage "Starting ${FUNCNAME[1]}..."
}

# Log the end of a function and its total duration.
EndFunctionLog() {
  local end_time=""
  end_time=$(date +%s)
  local duration=$((end_time - FUNC_START_TIME))
  WriteToLogs "### Finished ${FUNCNAME[1]} function in $duration seconds"
}

# Batch folder creation and permission setting.
# Pass a directory and a userID to this.
CreateFolderAndSetPermissions() {
  local dir_path="$1"
  local owner="$2"

  # Validate inputs
  if [ -z "$dir_path" ] || [ -z "$owner" ]; then
    WriteToLogs "Error: Missing parameters to CreateFolderAndSetPermissions"
    return 1
  fi

  # Check if the directory exists
  if [ -d "$dir_path" ]; then
    # Get current owner and permissions
    current_owner=$(stat -f "%Su" "$dir_path")
    current_perms=$(stat -f "%Lp" "$dir_path")

    if [[ "$current_owner" == "$owner" && "$current_perms" == "700" ]]; then
      WriteToLogs "Directory $dir_path already exists with correct owner and permissions — skipping."
      return 0
    else
      WriteToLogs "Directory $dir_path exists but needs ownership or permission correction."
    fi
  else
    # Try to create the directory
    if mkdir -p "$dir_path"; then
      WriteToLogs "Created directory: $dir_path"
    else
      WriteToLogs "Error: Failed to create directory $dir_path"
      return 1
    fi
  fi

  # Set ownership
  if chown "$owner" "$dir_path"; then
    WriteToLogs "Set ownership of $dir_path to $owner"
  else
    WriteToLogs "Error: Failed to set ownership of $dir_path to $owner"
    return 1
  fi

  # Set permissions
  if chmod 700 "$dir_path"; then
    WriteToLogs "Set permissions on $dir_path to 700"
  else
    WriteToLogs "Error: Failed to set permissions on $dir_path"
    return 1
  fi
}

# Check if the current user is an AD account.
# Sets the global $AD variable to 1 for AD, 0 for local.
CheckIfADAccount() {
  local accountCheck=""
  accountCheck=$(dscl . read /Users/"$CurrentUSER" OriginalAuthenticationAuthority 2>/dev/null)

  if [ "$accountCheck" != "" ]; then
    WriteToLogs "$CurrentUSER is an AD account"
    AD=1
  else
    WriteToLogs "$CurrentUSER is a local account"
    AD=0
  fi
}

# Check if the current user is a student or staff.
# Sets the global $ADUser variable to "Student" or "Staff".
CheckADUserType() {
  local accountCheck=""
  accountCheck=$(dscl . read /Users/"$CurrentUSER" OriginalAuthenticationAuthority 2>/dev/null)
  
  if [ "$accountCheck" != "" ] && [[ $CurrentUSER =~ ^[0-9] ]]; then
    WriteToLogs "$CurrentUSER is a student account"
    ADUser='Student'
  else
    WriteToLogs "$CurrentUSER is a staff account"
    ADUser='Staff'
  fi
}

# Set the global $MYHOMEDIR variable based on the mounted home directory path.
# Pass "Student" or "Staff" to this.

CheckFolderPath() {
  local userType="$1"
  local retries="${GMS_MOUNT_RETRIES:-12}"
  local retry_delay="${GMS_MOUNT_RETRY_DELAY_SECONDS:-5}"
  local mount_matches=""
  local match_count=0
  local mountpoint=""

  MYHOMEDIR=""

  while [ "$retries" -gt 0 ]; do
    mount_matches=$(mount | awk -v share="$userType" -v user="$CurrentUSER" '
      BEGIN {
        share = tolower(share)
        user = tolower(user)
      }
      {
        lower_line = tolower($0)
        if (index(lower_line, share) > 0 &&
            index(lower_line, "mounted by " user) > 0 &&
            index(lower_line, "nobrowse") == 0) {
          mountpoint = $0
          sub(/^.* on /, "", mountpoint)
          sub(/ \(.*/, "", mountpoint)
          print mountpoint
        }
      }
    ')
    match_count=$(printf '%s\n' "$mount_matches" | awk 'NF { count++ } END { print count + 0 }')

    if [ "$match_count" -eq 1 ]; then
      mountpoint="$mount_matches"
      break
    fi

    if [ "$match_count" -gt 1 ]; then
      WriteToLogs "Warning: Found $match_count possible $userType mountpoints for $CurrentUSER; redirection will be skipped."
      return 1
    fi

    retries=$((retries - 1))
    if [ "$retries" -gt 0 ]; then
      WriteToLogs "Network mount for $userType user not available yet; retrying in ${retry_delay}s ($retries retries left)."
      sleep "$retry_delay"
    fi
  done

  if [ -z "$mountpoint" ] || [ ! -d "$mountpoint" ]; then
    WriteToLogs "Warning: Unable to identify an available $userType network mount for $CurrentUSER."
    return 1
  fi

  MYHOMEDIR="$mountpoint/$CurrentUSER"
  if [ ! -d "$MYHOMEDIR" ] && ! mkdir -p "$MYHOMEDIR"; then
    WriteToLogs "Warning: Unable to access or create network home $MYHOMEDIR."
    MYHOMEDIR=""
    return 1
  fi

  WriteToLogs "Detected unique network home: $MYHOMEDIR"
  return 0
}

# Merge any data retained by an earlier redirection attempt.
MergeRedirectStaging() {
  local folder="$1"
  local remote_path="$2"
  local staging_base="$3"
  local stage_root=""
  local staged_path=""
  local merge_failed=0
  local nullglob_was_set=0
  local stage_roots=()

  shopt -q nullglob && nullglob_was_set=1
  shopt -s nullglob
  stage_roots=("$staging_base/${folder}."*)
  if [ "$nullglob_was_set" -eq 0 ]; then
    shopt -u nullglob
  fi

  for stage_root in "${stage_roots[@]-}"; do
    [ -n "$stage_root" ] || continue
    staged_path="$stage_root/$folder"
    if [[ "$(basename "$stage_root")" != ${folder}.[[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]] ]] ||
       [ ! -d "$stage_root" ] || [ -L "$stage_root" ] ||
       [ ! -d "$staged_path" ] || [ -L "$staged_path" ]; then
      WriteToLogs "Warning: Retained staging area $stage_root does not contain the expected $folder folder; it was left untouched."
      merge_failed=1
      continue
    fi

    WriteToLogs "Merging retained local contents from $staged_path into $remote_path; newest file wins and destination-only files are preserved."
    if RunRsyncWithNotifier "$staged_path/" "$remote_path/"; then
      if rm -rf "$stage_root" && [ ! -e "$stage_root" ]; then
        WriteToLogs "Merged retained contents for $folder and removed $stage_root."
      else
        WriteToLogs "Warning: Merge succeeded for $folder, but duplicate staged data could not be removed from $stage_root."
        merge_failed=1
      fi
    else
      WriteToLogs "CRITICAL: Merge failed for $folder; retained local data remains at $staged_path."
      merge_failed=1
    fi
  done

  rmdir "$staging_base" 2>/dev/null || true
  return "$merge_failed"
}

# Redirect folders in the local home directory to the remote home.
RedirectIfADAccount() {
  StartFunctionLog
  local local_home="$USERS_BASE_DIR/$CurrentUSER"
  local staging_base="$local_home/.gvsd_redirect_staging"
  local write_test=""
  local folders=("Pictures" "Documents" "Downloads" "Desktop")
  local folder=""

  if [ -z "$MYHOMEDIR" ] || [ "$MYHOMEDIR" = "/" ] || [ ! -d "$MYHOMEDIR" ]; then
    WriteToLogs "Warning: Network home is unavailable or unsafe; folder redirection skipped."
    EndFunctionLog
    return 1
  fi

  case "$MYHOMEDIR" in
    "$USERS_BASE_DIR"|"$USERS_BASE_DIR"/*)
      WriteToLogs "Warning: Refusing to redirect into local users path $MYHOMEDIR."
      EndFunctionLog
      return 1
      ;;
  esac

  write_test=$(mktemp "$MYHOMEDIR/.gvsd_login_write_test.XXXXXX" 2>/dev/null)
  if [ -z "$write_test" ] || [ ! -f "$write_test" ]; then
    WriteToLogs "Warning: Network home $MYHOMEDIR is not writable; folder redirection skipped."
    EndFunctionLog
    return 1
  fi
  rm -f "$write_test"

  WriteToLogs "Redirecting local folders to writable network home $MYHOMEDIR for $CurrentUSER."

  for folder in "${folders[@]}"; do
    local local_path="$local_home/$folder"
    local remote_path="$MYHOMEDIR/$folder"
    local stage_root=""
    local staged_path=""
    local current_target=""
    local previous_symlink_target=""
    local link_ready=0

    if ! mkdir -p "$remote_path"; then
      WriteToLogs "Warning: Could not create remote folder $remote_path; remaining redirections skipped."
      EndFunctionLog
      return 1
    fi

    if [ -L "$local_path" ]; then
      current_target=$(readlink "$local_path")
      if [ "$current_target" = "$remote_path" ]; then
        WriteToLogs "$local_path already redirects to $remote_path; no change needed."
        link_ready=1
      else
        if ! rm "$local_path"; then
          WriteToLogs "Warning: Could not remove incorrect symlink $local_path -> $current_target; remaining redirections skipped."
          EndFunctionLog
          return 1
        fi
        previous_symlink_target="$current_target"
        WriteToLogs "Removed incorrect symlink $local_path -> $current_target."
      fi
    elif [ -d "$local_path" ]; then
      if ! mkdir -p "$staging_base"; then
        WriteToLogs "Warning: Could not create local staging directory $staging_base; remaining redirections skipped."
        EndFunctionLog
        return 1
      fi
      chmod 700 "$staging_base" 2>/dev/null || true
      chown "$CurrentUSER" "$staging_base" 2>/dev/null || true

      stage_root=$(mktemp -d "$staging_base/${folder}.XXXXXX" 2>/dev/null)
      if [ -z "$stage_root" ] || [ ! -d "$stage_root" ]; then
        WriteToLogs "Warning: Could not create staging area for $local_path; remaining redirections skipped."
        EndFunctionLog
        return 1
      fi
      staged_path="$stage_root/$folder"

      if ! mv "$local_path" "$staged_path"; then
        WriteToLogs "Warning: Could not stage $local_path; original folder left in place."
        rmdir "$stage_root" 2>/dev/null || true
        EndFunctionLog
        return 1
      fi
      WriteToLogs "Staged existing local folder $local_path at $staged_path."
    elif [ -e "$local_path" ]; then
      WriteToLogs "Warning: $local_path exists but is not a directory or symlink; it was left untouched and remaining redirections were skipped."
      EndFunctionLog
      return 1
    fi

    if [ "$link_ready" -eq 0 ] && ! ln -s "$remote_path" "$local_path"; then
      WriteToLogs "Warning: Could not create symlink $local_path -> $remote_path."
      if [ -n "$staged_path" ] && [ -d "$staged_path" ] && [ ! -e "$local_path" ]; then
        if mv "$staged_path" "$local_path"; then
          WriteToLogs "Restored staged local folder to $local_path."
          rmdir "$stage_root" 2>/dev/null || true
          rmdir "$staging_base" 2>/dev/null || true
        else
          WriteToLogs "CRITICAL: Could not restore $local_path; retained data remains at $staged_path."
        fi
      elif [ -n "$previous_symlink_target" ] && [ ! -e "$local_path" ]; then
        if ln -s "$previous_symlink_target" "$local_path"; then
          WriteToLogs "Restored previous symlink $local_path -> $previous_symlink_target."
        else
          WriteToLogs "Warning: Could not restore previous symlink $local_path -> $previous_symlink_target."
        fi
      fi
      EndFunctionLog
      return 1
    fi
    if [ "$link_ready" -eq 0 ]; then
      WriteToLogs "Created symlink $local_path -> $remote_path."
    fi

    if ! MergeRedirectStaging "$folder" "$remote_path" "$staging_base"; then
      WriteToLogs "Warning: One or more retained staging areas for $folder could not be fully recovered."
      EndFunctionLog
      return 1
    fi
  done

  EndFunctionLog
  return 0
}

ClearRedirectState() {
  local state_path="$USERS_BASE_DIR/$CurrentUSER/$REDIRECT_STATE_REL"

  if [ -e "$state_path" ] || [ -L "$state_path" ]; then
    if rm -f "$state_path"; then
      WriteToLogs "Cleared previous home-folder redirection state."
    else
      WriteToLogs "Warning: Could not clear previous redirection state $state_path."
      return 1
    fi
  fi
  return 0
}

WriteRedirectState() {
  local local_home="$USERS_BASE_DIR/$CurrentUSER"
  local state_path="$local_home/$REDIRECT_STATE_REL"
  local state_dir=""
  local folder=""
  local link_path=""
  local expected_target=""
  local actual_target=""
  local folders=("Desktop" "Documents" "Downloads" "Pictures")

  if [ -z "$MYHOMEDIR" ] || [ ! -d "$MYHOMEDIR" ]; then
    WriteToLogs "Warning: Cannot record redirection state without an available network home."
    return 1
  fi

  for folder in "${folders[@]}"; do
    link_path="$local_home/$folder"
    expected_target="$MYHOMEDIR/$folder"
    if [ ! -L "$link_path" ]; then
      WriteToLogs "Warning: Cannot record redirection state; $link_path is not a symlink."
      return 1
    fi
    actual_target=$(readlink "$link_path")
    if [ "$actual_target" != "$expected_target" ] || [ ! -d "$expected_target" ]; then
      WriteToLogs "Warning: Cannot record redirection state; $link_path does not resolve to available target $expected_target."
      return 1
    fi
  done

  state_dir=$(dirname "$state_path")
  if ! mkdir -p "$state_dir"; then
    WriteToLogs "Warning: Could not create redirection state directory $state_dir."
    return 1
  fi

  if ! printf 'version=1\nnetwork_home=%s\nverified_at=%s\n' \
      "$MYHOMEDIR" "$(date +%s)" > "$state_path"; then
    WriteToLogs "Warning: Could not write redirection state $state_path."
    return 1
  fi
  chown "$CurrentUSER" "$state_path" 2>/dev/null || WriteToLogs "Warning: Could not set owner on $state_path."
  chmod 600 "$state_path" 2>/dev/null || WriteToLogs "Warning: Could not set permissions on $state_path."
  WriteToLogs "Recorded verified home-folder redirection state for $MYHOMEDIR."
  return 0
}

# Replace the default pinned Sidebar folders with new shortcuts.
PinRedirectedFolders() {
  StartFunctionLog

  local uid=""
  local mysides_bin=""

  uid=$(id -u "$CurrentUSER")

  for candidate in "/usr/local/bin/mysides" "/opt/homebrew/bin/mysides"; do
    if [[ -x "$candidate" ]]; then
      mysides_bin="$candidate"
      break
    fi
  done

  if [[ -z "$mysides_bin" ]]; then
    WriteToLogs "Error: mysides not found."
    EndFunctionLog
    return 1
  fi

  run_as_current_user() {
    launchctl asuser "$uid" sudo -u "$CurrentUSER" env HOME="$USERS_BASE_DIR/$CurrentUSER" "$@"
  }

  update_sidebar_item() {
    local name="$1"
    local url="$2"

    WriteToLogs "Updating sidebar favorite for $name"
    run_as_current_user "$mysides_bin" remove "$name" >/dev/null 2>&1 || true

    if run_as_current_user "$mysides_bin" add "$name" "$url" >> "$SYNCLOG" 2>&1; then
      WriteToLogs "Updated sidebar favorite for $name -> $url"
    else
      WriteToLogs "Error: failed to add sidebar favorite for $name -> $url"
      return 1
    fi
  }

  # Give macOS a moment to settle the mount
  sleep 2

  local folders=("Desktop" "Documents" "Downloads" "Pictures")
  local status=0

  for name in "${folders[@]}"; do
    update_sidebar_item "$name" "file:///${MYHOMEDIR#/}/$name" || status=1
  done

  update_sidebar_item "Music" "file:///${USERS_BASE_DIR#/}/$CurrentUSER/Music" || status=1

  run_as_current_user killall sharedfilelistd 2>/dev/null || true

  EndFunctionLog
  return "$status"
}

CreateDocumentLibraryFolders() {
  StartFunctionLog
  
  # Set of folders to create
  local directories=(
    "Documents/Application Support"
    "Documents/Application Support/minecraft"
    "Documents/Application Support/minecraft/saves"
    "Documents/Application Support/Google/Chrome/Profile 1"
    "Documents/GarageBand"
    "Documents/Sync"
    "Documents/Sync/Twine"
    "Documents/Sync/Twine/Stories"
    "Documents/Sync/Twine/Backups"
    "Twine"
    "Library/Application Support"
    "Library/Application Support/minecraft"
    "Library/Application Support/minecraft/saves"
    "Music/Audio Music Apps"
    "Music/GarageBand"
    "Library/Application Support/Google"
    "Library/Application Support/Google/Chrome"
    "Library/Application Support/Google/Chrome/Profile 1" 
  )
  
  for dir in "${directories[@]}"; do
    CreateFolderAndSetPermissions "/Users/$CurrentUSER/$dir" "$CurrentUSER"
  done

  EndFunctionLog
}

# Replace an application data folder with a symlink without discarding existing data.
RedirectAppFolderSafely() {
  local source_path="$1"
  local target_path="$2"
  local label="$3"
  local source_parent=""
  local source_name=""
  source_parent=$(dirname "$source_path")
  source_name=$(basename "$source_path")
  local staging_base="$source_parent/.gvsd_app_redirect_staging"
  local current_target=""
  local previous_symlink_target=""
  local stage_root=""
  local staged_path=""
  local link_ready=0
  local merge_failed=0
  local nullglob_was_set=0
  local stage_roots=()

  if ! mkdir -p "$target_path"; then
    WriteToLogs "Warning: Could not create $label target $target_path; redirection skipped."
    return 1
  fi

  if [ -L "$source_path" ]; then
    current_target=$(readlink "$source_path")
    if [ "$current_target" = "$target_path" ]; then
      WriteToLogs "$label symlink already correct: $source_path -> $target_path."
      link_ready=1
    else
      if ! rm "$source_path"; then
        WriteToLogs "Warning: Could not remove incorrect $label symlink $source_path -> $current_target."
        return 1
      fi
      previous_symlink_target="$current_target"
      WriteToLogs "Removed incorrect $label symlink $source_path -> $current_target."
    fi
  elif [ -d "$source_path" ]; then
    if ! mkdir -p "$staging_base"; then
      WriteToLogs "Warning: Could not create $label staging directory $staging_base."
      return 1
    fi
    chmod 700 "$staging_base" 2>/dev/null || true
    chown "$CurrentUSER" "$staging_base" 2>/dev/null || true

    stage_root=$(mktemp -d "$staging_base/${source_name}.XXXXXX" 2>/dev/null)
    if [ -z "$stage_root" ] || [ ! -d "$stage_root" ]; then
      WriteToLogs "Warning: Could not create a staging area for $source_path."
      return 1
    fi
    staged_path="$stage_root/$source_name"

    if ! mv "$source_path" "$staged_path"; then
      WriteToLogs "Warning: Could not stage existing $label folder $source_path; it was left in place."
      rmdir "$stage_root" 2>/dev/null || true
      rmdir "$staging_base" 2>/dev/null || true
      return 1
    fi
    WriteToLogs "Staged existing $label folder $source_path at $staged_path."
  elif [ -e "$source_path" ]; then
    WriteToLogs "Warning: $label path $source_path is not a directory or symlink; it was left untouched."
    return 1
  fi

  if [ "$link_ready" -eq 0 ]; then
    if ! ln -s "$target_path" "$source_path"; then
      WriteToLogs "Warning: Could not create $label symlink $source_path -> $target_path."
      if [ -n "$staged_path" ] && [ -d "$staged_path" ] && [ ! -e "$source_path" ]; then
        if mv "$staged_path" "$source_path"; then
          WriteToLogs "Restored the staged $label folder to $source_path."
          rmdir "$stage_root" 2>/dev/null || true
          rmdir "$staging_base" 2>/dev/null || true
        else
          WriteToLogs "CRITICAL: Could not restore $label; retained data remains at $staged_path."
        fi
      elif [ -n "$previous_symlink_target" ] && [ ! -e "$source_path" ]; then
        if ln -s "$previous_symlink_target" "$source_path"; then
          WriteToLogs "Restored previous $label symlink $source_path -> $previous_symlink_target."
        else
          WriteToLogs "Warning: Could not restore previous $label symlink $source_path -> $previous_symlink_target."
        fi
      fi
      return 1
    fi
    WriteToLogs "Created $label symlink $source_path -> $target_path."
  fi

  shopt -q nullglob && nullglob_was_set=1
  shopt -s nullglob
  stage_roots=("$staging_base/${source_name}."*)
  [ "$nullglob_was_set" -eq 0 ] && shopt -u nullglob

  for stage_root in "${stage_roots[@]-}"; do
    [ -n "$stage_root" ] || continue
    staged_path="$stage_root/$source_name"
    if [[ "$(basename "$stage_root")" != ${source_name}.[[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]] ]] ||
       [ ! -d "$stage_root" ] || [ -L "$stage_root" ] ||
       [ ! -d "$staged_path" ] || [ -L "$staged_path" ]; then
      WriteToLogs "Warning: Suspicious $label staging area $stage_root was left untouched."
      continue
    fi

    WriteToLogs "Merging retained $label contents from $staged_path into $target_path; newest file wins."
    if RunRsyncWithNotifier "$staged_path/" "$target_path/"; then
      if rm -rf "$stage_root" && [ ! -e "$stage_root" ]; then
        WriteToLogs "Merged retained $label contents and removed $stage_root."
      else
        WriteToLogs "Warning: $label merge succeeded, but duplicate staging data remains at $stage_root."
        merge_failed=1
      fi
    else
      WriteToLogs "CRITICAL: $label merge failed; retained data remains at $staged_path."
      merge_failed=1
    fi
  done

  rmdir "$staging_base" 2>/dev/null || true
  return "$merge_failed"
}

# Retire a symlink previously created by this script without touching its target.
RemoveManagedFolderRedirect() {
  local source_path="$1"
  local managed_target="$2"
  local label="$3"
  local current_target=""

  if [ ! -L "$source_path" ]; then
    if [ -e "$source_path" ]; then
      WriteToLogs "$label uses a normal local path; no legacy redirection cleanup needed."
    else
      WriteToLogs "$label legacy redirection is not present; no cleanup needed."
    fi
    return 0
  fi

  current_target=$(readlink "$source_path")
  if [ "$current_target" != "$managed_target" ]; then
    WriteToLogs "Warning: $label symlink $source_path points to unexpected target $current_target; it was left untouched."
    return 1
  fi

  if ! rm "$source_path"; then
    WriteToLogs "Warning: Could not remove legacy $label symlink $source_path -> $managed_target."
    return 1
  fi

  if mkdir -p "$source_path"; then
    chown "$CurrentUSER" "$source_path" 2>/dev/null || WriteToLogs "Warning: Could not set owner on restored local $label folder $source_path."
    chmod 700 "$source_path" 2>/dev/null || WriteToLogs "Warning: Could not set permissions on restored local $label folder $source_path."
    WriteToLogs "Removed legacy $label redirection and restored local folder $source_path; network data at $managed_target was left untouched."
    return 0
  fi

  WriteToLogs "Warning: Removed legacy $label symlink but could not create local folder $source_path."
  if ln -s "$managed_target" "$source_path"; then
    WriteToLogs "Restored legacy $label symlink after local folder creation failed."
  else
    WriteToLogs "CRITICAL: Could not restore legacy $label symlink $source_path -> $managed_target."
  fi
  return 1
}

LinkLibraryFolders() {
  StartFunctionLog
  
  # Ensure shared Minecraft directory exists
  mkdir -p "/Users/Shared/minecraft" || WriteToLogs "Failed to create directory /Users/Shared/minecraft"
  mkdir -p "/Users/$CurrentUSER/Library/Application Support/minecraft" || WriteToLogs "Failed to create directory /Users/$CurrentUSER/Library/Application Support/minecraft"
  
  local mineFolders=("assets" "versions")
  
  for m in "${mineFolders[@]}"; do
    RedirectAppFolderSafely \
      "/Users/$CurrentUSER/Library/Application Support/minecraft/$m" \
      "/Users/Shared/minecraft/$m" \
      "Minecraft $m" || WriteToLogs "Warning: Minecraft $m redirection was not completed."
  done
  
  RemoveManagedFolderRedirect \
    "/Users/$CurrentUSER/Library/Application Support/Dock" \
    "/Users/$CurrentUSER/Documents/Application Support/Dock" \
    "Dock" || WriteToLogs "Warning: Legacy Dock redirection cleanup was not completed."

  local appSubfolders=("iMovie")
  
  for x in "${appSubfolders[@]}"; do
    RedirectAppFolderSafely \
      "/Users/$CurrentUSER/Library/Application Support/$x" \
      "/Users/$CurrentUSER/Documents/Application Support/$x" \
      "$x" || WriteToLogs "Warning: $x redirection was not completed."
  done
  
  EndFunctionLog
}


LinkTwineFolders() {
  StartFunctionLog

  local twine_target="/Users/$CurrentUSER/Twine"
  local twine_link="/Users/$CurrentUSER/Documents/Twine"

  if ! RedirectAppFolderSafely "$twine_link" "$twine_target" "Twine"; then
    WriteToLogs "Warning: Twine redirection was not completed."
    EndFunctionLog
    return 1
  fi

  chown "$CurrentUSER" "$twine_target" 2>/dev/null || WriteToLogs "Warning: Failed to set ownership of $twine_target"

  EndFunctionLog
}

FixLibraryPerms() {
  StartFunctionLog

  set_shared_minecraft_permissions() {
    local cache_root="/Users/Shared/minecraft"

    if [ ! -d "$cache_root" ]; then
      WriteToLogs "Shared Minecraft cache $cache_root not found."
      return 1
    fi

    # The cache must be writable by every lab user, but data files do not need
    # executable bits. Normalize it before the current user launches Minecraft.
    if ! chown -R root:wheel "$cache_root"; then
      WriteToLogs "Warning: Could not normalize ownership for $cache_root."
    fi
    if ! find -P "$cache_root" -type d -exec chmod 777 {} +; then
      WriteToLogs "Warning: Could not normalize directory permissions in $cache_root."
      return 1
    fi
    if ! find -P "$cache_root" -type f -exec chmod 666 {} +; then
      WriteToLogs "Warning: Could not normalize file permissions in $cache_root."
      return 1
    fi
    chmod 1777 "$cache_root" || WriteToLogs "Warning: Could not set the sticky bit on $cache_root."
    WriteToLogs "Shared Minecraft cache permissions normalized: writable directories, non-executable data files."
  }

  set_private_minecraft_permissions() {
    local minecraft_home="/Users/$CurrentUSER/Library/Application Support/minecraft"

    if [ ! -d "$minecraft_home" ]; then
      WriteToLogs "Minecraft user data directory $minecraft_home not found."
      return 1
    fi

    # Do not follow the assets or versions symlinks into the shared cache.
    if ! find -P "$minecraft_home" \( -type d -o -type f \) -exec chown "$CurrentUSER" {} +; then
      WriteToLogs "Warning: Could not normalize ownership in $minecraft_home."
    fi
    if ! find -P "$minecraft_home" \( -type d -o -type f \) -exec chmod go-rwx {} +; then
      WriteToLogs "Warning: Could not make Minecraft user data private in $minecraft_home."
      return 1
    fi
    WriteToLogs "Minecraft user data permissions restricted to $CurrentUSER without following shared-cache symlinks."
  }

  verify_minecraft_app_signature() {
    local app_path="/Applications/Minecraft.app"
    local signature_error=""

    if [ ! -d "$app_path" ]; then
      WriteToLogs "Warning: Minecraft application not found at $app_path."
      return 1
    fi

    if signature_error=$(codesign --verify --deep --strict "$app_path" 2>&1); then
      WriteToLogs "Minecraft application signature verification passed."
      return 0
    fi

    signature_error=${signature_error//$'\n'/; }
    WriteToLogs "Warning: Minecraft application signature verification failed: $signature_error"
    return 1
  }
  
  adjust_permissions() {
    local dir_path="$1"
    local desired_perm="$2"
    local owner="$3"
    local group="$4"
  
    if [ -d "$dir_path" ]; then
      [ -n "$owner" ] && chown -R "$owner:$group" "$dir_path" && WriteToLogs "Set ownership for $dir_path"
      chmod -R "$desired_perm" "$dir_path" && WriteToLogs "Set permissions for $dir_path"
    else
      WriteToLogs "Directory $dir_path not found"
    fi
  }
  
    # The launcher currently requires student write access to update itself.
    # Retain that behavior while logging signature damage for diagnosis.
    adjust_permissions "/Applications/Minecraft.app" "777"
    verify_minecraft_app_signature || true
    set_shared_minecraft_permissions || true
    set_private_minecraft_permissions || true
    adjust_permissions "/Users/$CurrentUSER/Documents/Application Support/minecraft" "700" "$CurrentUSER"
    adjust_permissions "/Users/$CurrentUSER/Documents/Application Support/minecraft/saves" "700" "$CurrentUSER"
    adjust_permissions "/Users/$CurrentUSER/Music/Audio Music Apps" "700" "$CurrentUSER"
    adjust_permissions "/Users/$CurrentUSER/Music/GarageBand" "700" "$CurrentUSER"
    adjust_permissions "/Users/$CurrentUSER/Library/Application Support/Google" "700" "$CurrentUSER"
  
  EndFunctionLog
}

SyncFiles() {
  StartFunctionLog

  local srcBase="/Users/$CurrentUSER/Documents/Application Support/minecraft"
  local destBase="/Users/$CurrentUSER/Library/Application Support/minecraft"
  local sync_failures=0

  # Function to sync directories with checks
  sync_directory() {
    local src=$1
    local dest=$2
    local name=$3

    if [ -d "$src" ]; then
      if ! mkdir -p "$dest"; then
        WriteToLogs "Error creating destination $dest for $name."
        sync_failures=$((sync_failures + 1))
        return
      fi

      WriteToLogs "Syncing $name with newest-file-wins behavior; destination-only files will be preserved."
      if RunRsyncWithNotifier "$src/" "$dest/"; then
        WriteToLogs "Successfully synced $name from $src to $dest."
      else
        WriteToLogs "Error syncing $name from $src to $dest."
        sync_failures=$((sync_failures + 1))
      fi
    else
      WriteToLogs "Source directory $src for $name does not exist. Skipping."
    fi
  }

  # Sync Minecraft directories
  sync_directory "$srcBase/saves" "$destBase/saves" "Minecraft saves"
  sync_directory "$srcBase/curseforge" "$destBase/curseforge" "Minecraft curseforge"

  # Sync individual Minecraft files
  local files=("launcher_accounts.json" "launcher_msa_credentials.bin" "options.txt")
  for file in "${files[@]}"; do
    if [ -e "$srcBase/$file" ]; then
      WriteToLogs "Syncing $file with newest-file-wins behavior; destination-only files will be preserved."
      if RunRsyncWithNotifier "$srcBase/$file" "$destBase/"; then
        WriteToLogs "Successfully synced $file from $srcBase to $destBase."
      else
        WriteToLogs "Error syncing $file from $srcBase to $destBase."
        sync_failures=$((sync_failures + 1))
      fi
    else
      WriteToLogs "File $srcBase/$file does not exist. Skipping."
    fi
  done

  # Sync GarageBand and Twine folders
  sync_directory "/Users/$CurrentUSER/Documents/GarageBand" "/Users/$CurrentUSER/Music/GarageBand" "GarageBand"
  sync_directory "/Users/$CurrentUSER/Documents/Sync/Twine" "/Users/$CurrentUSER/Twine" "Twine"

  EndFunctionLog

  if [ "$sync_failures" -gt 0 ]; then
    WriteToLogs "SyncFiles completed with $sync_failures failed sync operation(s)."
    return 1
  fi

  WriteToLogs "SyncFiles completed successfully."
  return 0
}

DeleteOldLocalHomes() {
  StartFunctionLog

  local base_dir="$USERS_BASE_DIR"
  local size_threshold_kb="$LOCAL_CONTENT_SIZE_THRESHOLD_KB"
  local now_epoch=""
  local user_entries=()
  local dotglob_was_set=0
  local nullglob_was_set=0

  CLEANUP_HOMES_DELETED_KB=0
  CLEANUP_FOLDERS_PRUNED_KB=0
  now_epoch=$(date +%s)

  if [ ! -d "$base_dir" ]; then
    WriteToLogs "Warning: Local users directory $base_dir does not exist; cleanup skipped."
    EndFunctionLog
    return 1
  fi

  shopt -q dotglob && dotglob_was_set=1
  shopt -q nullglob && nullglob_was_set=1
  shopt -s dotglob nullglob
  user_entries=("$base_dir"/*)
  [ "$dotglob_was_set" -eq 0 ] && shopt -u dotglob
  [ "$nullglob_was_set" -eq 0 ] && shopt -u nullglob

  for dir in "${user_entries[@]}"; do

    if [ -L "$dir" ]; then
      WriteToLogs "Skipping $dir: local users entry is a symlink."
      continue
    fi
    if [ ! -d "$dir" ]; then
      WriteToLogs "Skipping $dir: local users entry is not a directory."
      continue
    fi

    local username=""
    local age_days=""
    local age_source=""
    local age_epoch=""
    local age_timestamp=""

    username=$(basename "$dir")
    WriteToLogs "Testing local home for $username at $dir."

    if IsProtectedLocalHome "$username"; then
      WriteToLogs "$username: skipped protected account."
      continue
    fi

    if [ "$username" = "$CurrentUSER" ]; then
      WriteToLogs "$username: skipped active user; login stamp will be updated after cleanup."
      continue
    fi

    GetLocalHomeAge "$dir" "$now_epoch"
    local age_status=$?

    if [ "$age_status" -eq 2 ]; then
      WriteToLogs "$username: delete unstamped local home; no login stamp exists."
      RemoveLocalPath "$username" "$dir" "unstamped local home" "home"
      continue
    fi

    if [ "$age_status" -ne 0 ]; then
      WriteToLogs "$username: skipped; could not determine a reliable age for local home."
      continue
    fi

    age_days="$LOCAL_HOME_AGE_DAYS"
    age_source="$LOCAL_HOME_AGE_SOURCE"
    age_epoch="$LOCAL_HOME_AGE_EPOCH"
    age_timestamp=$(date -r "$age_epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")

    WriteToLogs "Age signal for $username: source=$age_source; timestamp=$age_timestamp; age=${age_days} days."

    # If the user has not logged in for the configured old-age threshold, wipe the whole local home.
    if [ "$age_days" -ge "$OLD_AGE_THRESHOLD" ]; then
      WriteToLogs "$username: delete stale local home; age ${age_days} days meets $OLD_AGE_THRESHOLD day threshold."
      RemoveLocalPath "$username" "$dir" "local home" "home"
      continue
    fi

    if [ "$age_days" -lt "$AGE_THRESHOLD" ]; then
      WriteToLogs "$username: no cleanup; age ${age_days} days is younger than $AGE_THRESHOLD day threshold."
      continue
    fi

    WriteToLogs "$username: inspect high-size local content; age ${age_days} days is between $AGE_THRESHOLD and $OLD_AGE_THRESHOLD days."
    CleanLargeLocalContent "$username" "$dir" "$size_threshold_kb"
  done

  if [ "${#user_entries[@]}" -eq 0 ]; then
    WriteToLogs "No local user entries found under $base_dir."
  fi

  local total_reclaimed_kb=$((CLEANUP_HOMES_DELETED_KB + CLEANUP_FOLDERS_PRUNED_KB))
  WriteToLogs "Cleanup summary: reclaimed $(FormatSizeKB "$total_reclaimed_kb") total ($(FormatSizeKB "$CLEANUP_HOMES_DELETED_KB") from deleted homes; $(FormatSizeKB "$CLEANUP_FOLDERS_PRUNED_KB") from pruned folders)."

  EndFunctionLog
}

IsProtectedLocalHome() {
  local username="$1"

  [[ "$username" =~ ^(Shared|Guest|admin|helpdesk|jweston|\.localized)$ ]]
}

GetLocalHomeAge() {
  local dir="$1"
  local now_epoch="$2"
  local marker="$dir/$LOCAL_LOGIN_STAMP_REL"
  local marker_epoch=""

  LOCAL_HOME_AGE_DAYS=""
  LOCAL_HOME_AGE_SOURCE=""
  LOCAL_HOME_AGE_EPOCH=""

  if [ -f "$marker" ]; then
    marker_epoch=$(stat -f "%m" "$marker" 2>/dev/null)
    if [[ "$marker_epoch" =~ ^[0-9]+$ ]]; then
      LOCAL_HOME_AGE_DAYS=$(( (now_epoch - marker_epoch) / 86400 ))
      [ "$LOCAL_HOME_AGE_DAYS" -lt 0 ] && LOCAL_HOME_AGE_DAYS=0
      LOCAL_HOME_AGE_SOURCE="login-stamp:$marker"
      LOCAL_HOME_AGE_EPOCH="$marker_epoch"
      return 0
    fi
    WriteToLogs "Warning: login stamp exists but could not be read: $marker"
  else
    WriteToLogs "No login stamp found for $dir."
    return 2
  fi

  return 1
}

GetPathSizeKB() {
  local target="$1"
  local size_kb=""

  size_kb=$(du -sk "$target" 2>/dev/null | awk 'NR == 1 { print $1 }')
  if [[ "$size_kb" =~ ^[0-9]+$ ]]; then
    printf '%s' "$size_kb"
    return 0
  fi

  return 1
}

FormatSizeKB() {
  local size_kb="$1"

  if ! [[ "$size_kb" =~ ^[0-9]+$ ]]; then
    printf 'unknown size'
  elif [ "$size_kb" -ge 1048576 ]; then
    awk -v kb="$size_kb" 'BEGIN { printf "%.1fGiB", kb / 1048576 }'
  elif [ "$size_kb" -ge 1024 ]; then
    awk -v kb="$size_kb" 'BEGIN { printf "%.1fMiB", kb / 1024 }'
  else
    printf '%sKiB' "$size_kb"
  fi
}

RemoveLocalPath() {
  local username="$1"
  local target="$2"
  local label="$3"
  local category="$4"
  local target_size_kb=0

  if ! target_size_kb=$(GetPathSizeKB "$target"); then
    target_size_kb=0
    WriteToLogs "$username: warning; could not determine size before deleting $target."
  fi

  if rm -rf "$target"; then
    if [ -e "$target" ]; then
      WriteToLogs "$username: rm completed but $target still exists."
      return 1
    fi

    case "$category" in
      home)
        CLEANUP_HOMES_DELETED_KB=$((CLEANUP_HOMES_DELETED_KB + target_size_kb))
        ;;
      prune)
        CLEANUP_FOLDERS_PRUNED_KB=$((CLEANUP_FOLDERS_PRUNED_KB + target_size_kb))
        ;;
    esac

    WriteToLogs "$username: deleted $label $target; reclaimed $(FormatSizeKB "$target_size_kb")."
    return 0
  fi

  WriteToLogs "$username: failed to delete $label $target."
  return 1
}

CleanLargeLocalContent() {
  local username="$1"
  local dir="$2"
  local size_threshold_kb="$3"
  local folders_to_check=(
    "$dir/Library/Application Support/minecraft/saves"
    "$dir/Music/GarageBand"
    "$dir/Library/Caches"
  )

  for target in "${folders_to_check[@]}"; do
    if [ -L "$target" ]; then
      WriteToLogs "$username: cleanup target is a symlink, skipped: $target"
      continue
    fi
    if [ ! -d "$target" ]; then
      WriteToLogs "$username: cleanup target missing, skipped: $target"
      continue
    fi

    local folder_size_kb=""
    if ! folder_size_kb=$(GetPathSizeKB "$target"); then
      WriteToLogs "$username: could not determine size for $target; skipped."
      continue
    fi

    if [ "$folder_size_kb" -gt "$size_threshold_kb" ]; then
      WriteToLogs "$username: delete large local content $target ($(FormatSizeKB "$folder_size_kb") > $(FormatSizeKB "$size_threshold_kb"))."
      RemoveLocalPath "$username" "$target" "large local content" "prune"
    else
      WriteToLogs "$username: kept $target ($(FormatSizeKB "$folder_size_kb") <= $(FormatSizeKB "$size_threshold_kb"))."
    fi
  done
}

UpdateCurrentLoginStamp() {
  StartFunctionLog

  local marker_parent=""
  local marker_dir=""
  local marker_path="$USERS_BASE_DIR/$CurrentUSER/$LOCAL_LOGIN_STAMP_REL"

  marker_parent=$(dirname "$LOCAL_LOGIN_STAMP_REL")
  marker_dir="$USERS_BASE_DIR/$CurrentUSER/$marker_parent"

  if [ -z "$CurrentUSER" ] || [ "$CurrentUSER" = "loginwindow" ]; then
    WriteToLogs "ERROR: Current user is not available; cannot update local login stamp."
    EndFunctionLog
    return 1
  fi

  if mkdir -p "$marker_dir" && touch "$marker_path"; then
    chown "$CurrentUSER" "$marker_path" 2>/dev/null || WriteToLogs "Warning: could not set owner on $marker_path"
    WriteToLogs "Updated local login stamp for $CurrentUSER at $marker_path."
  else
    WriteToLogs "ERROR: Failed to update local login stamp for $CurrentUSER at $marker_path."
    EndFunctionLog
    return 1
  fi

  EndFunctionLog
}


OnExit() {
  jamf policy -event synctohome
}

#################
# MAIN SEQUENCE #
#################

# Wrap the sequence in a progress UI.
display_progress() {
  local local_home="$USERS_BASE_DIR/$CurrentUSER"

  WriteToLogs "Login script started (script version $SCRIPT_VERSION)"
  WriteToLogs "Current User: $CurrentUSER"

  if mkdir -p "$local_home/Library/Application Support"; then
    touch "$local_home/Library/Application Support/com.gvsd.LogonScriptRun.plist" || WriteToLogs "Warning: Could not create login-run marker."
  else
    WriteToLogs "Warning: Could not create Application Support folder for login-run marker."
  fi
  if [ -e "$local_home/Library/Preferences/com.apple.dock.plist" ]; then
    chown "$CurrentUSER" "$local_home/Library/Preferences/com.apple.dock.plist" || WriteToLogs "Warning: Could not set Dock preferences owner."
  fi

  ClearRedirectState || true

  CheckIfADAccount
  
  if [ $AD = "1" ]; then
    CheckADUserType
  else
    WriteToLogs "Current user is not an AD account."
    return 1
  fi
  
  # Launch the IBM Notifier app UI with the following config, and background it.
  "${APP_PATH}" \
    -type "popup" \
    -silent \
    -position top_left \
    -title "${PROG_TITLE}" \
    -bar_title "${PROG_BAR_TITLE}" \
    -accessory_view_type "${PROG_ACCESSORY_TYPE}" \
    -timeout "${PROG_TIMEOUT_SECONDS}" \
    -accessory_view_payload "${PROG_ACCESSORY_PAYLOAD}" < "$PIPE_PATH" &
  Notifier_Process=$!
  
  if [ "$ADUser" = "Student" ] || [ "$ADUser" = "Staff" ]; then
    if ! CheckFolderPath "$ADUser"; then
      WriteToLogs "Warning: Network home detection failed; redirection will be skipped."
    fi
  else
    WriteToLogs "Unknown ADUser value: $ADUser" 
  fi
    
  WriteToLogs "Home Folder is $MYHOMEDIR"
  
  if RedirectIfADAccount; then
    if WriteRedirectState; then
      if ! PinRedirectedFolders; then
        WriteToLogs "Warning: Sidebar favorites could not be updated; login will continue."
      fi
    else
      WriteToLogs "Warning: Folder links could not be verified; no successful redirection state was recorded."
    fi
  else
    WriteToLogs "Warning: Folder redirection was skipped or incomplete; sidebar updates were skipped."
  fi

  CreateDocumentLibraryFolders
  LinkLibraryFolders
  LinkTwineFolders
  FixLibraryPerms
  if ! SyncFiles; then
    WriteToLogs "Warning: One or more login sync operations failed; login will continue."
  fi
  WriteToLogs "Login script complete."
  
  # Tell the progress UI to close, and clean up.
  printf '/percent 100\n' >&3
  CleanupLoginRuntime
  return 0
}

main() {
  if ! InitializeLoginScript; then
    return 1
  fi
  if ! ValidateCurrentUser; then
    return 1
  fi

  # Do the main sequence, wrapped by the progress UI.
  # Delete the stale local homes after the UI has closed, as we don't need to watch it.
  if ! display_progress; then
    return 1
  fi
  DeleteOldLocalHomes
  UpdateCurrentLoginStamp
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
  exit $?
fi
