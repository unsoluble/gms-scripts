#!/bin/bash

####################################################################################
# Script to handle folder redirections and permissions for student & staff logins. #
####################################################################################

# Set global variables.
SCRIPT_VERSION="2026-05-19-1845"
CurrentUSER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /Loginwindow/ { print $3 }' )
SYNCLOG="/tmp/LibrarySync.log"
# Age threshold for local home cleanup (days)
AGE_THRESHOLD=15
# Age threshold for local home deletion (days)
OLD_AGE_THRESHOLD=60
# Local marker used to record the last completed login for cleanup age checks.
LOCAL_LOGIN_STAMP_REL="Library/Application Support/com.gvsd.LocalHomeLastLogin"

# Notifier UI paths.
APP_PATH="/Applications/IBM Notifier.app/Contents/MacOS/IBM Notifier"

# Variables for the progress dialog.
PROG_BAR_TITLE="Logging In"
PROG_TITLE="Syncing your files! Your stuff will be ready when this finishes."
PROG_ACCESSORY_TYPE="progressbar"
PROG_ACCESSORY_PAYLOAD="/percent indeterminate \
                        /user_interruption_allowed false \
                        /exit_on_completion true"

# Set up a temporary pipe for the sync progress window.
PIPE_NAME="login_pipe"
rm -f "/tmp/${PIPE_NAME}"
mkfifo "/tmp/${PIPE_NAME}"
exec 3<> "/tmp/${PIPE_NAME}"

# Rotate the logs.
if [ -f "$SYNCLOG" ]; then
  mv "$SYNCLOG" "/tmp/LibrarySync-$(date +%Y-%m-%d_%H-%M-%S).log"
fi
# Delete archived logs older than 2 days.
find /tmp -name "LibrarySync-*.log" -mtime +2 -exec rm {} \;

# Declare a global for the function logging routines.
FUNC_START_TIME=""

touch "$SYNCLOG"
chmod 777 "$SYNCLOG"
chmod 777 "/usr/local/ConsoleUserWarden/bin/ConsoleUserWarden-UserLoggedOut"

#############
# FUNCTIONS #
#############

# Logs to both the console and the global logfile.
WriteToLogs() {
  local message="$1"
  local now=$(date "+%Y-%m-%d %T")
  echo "$now - $message" >> "$SYNCLOG"
  echo "$now - $message"
}

# Log the start of a function, and capture the time for its duration.
StartFunctionLog() {
  FUNC_START_TIME=$(date +%s)
  WriteToLogs "### Started ${FUNCNAME[1]} function" # FUNCNAME[1] is the name of the calling function
  echo -n "/bottom_message Starting ${FUNCNAME[1]}..." >&3
}

# Log the end of a function and its total duration.
EndFunctionLog() {
  local end_time=$(date +%s)
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
  local loggedInUser=$(stat -f%Su /dev/console)
  local accountCheck=$(dscl . read /Users/$loggedInUser OriginalAuthenticationAuthority 2>/dev/null)

  if [ "$accountCheck" != "" ]; then
    WriteToLogs "$loggedInUser is an AD account"
    AD=1
  else
    WriteToLogs "$loggedInUser is a local account"
    AD=0
  fi
}

# Check if the current user is a student or staff.
# Sets the global $ADUser variable to "Student" or "Staff".
CheckADUserType() {
  local accountCheck=$(dscl . read /Users/$CurrentUSER OriginalAuthenticationAuthority 2>/dev/null)
  
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
  local unescapedDir=$(mount | grep -i $1 | grep "mounted by ${CurrentUSER}" | grep -v "nobrowse" | awk -F ' on ' '{print $2}' | awk '{print $1}')
  MYHOMEDIR="$unescapedDir/$CurrentUSER"
  WriteToLogs "Detected mountpoint is $MYHOMEDIR"
}

# Redirect folders in the local home directory to the remote home.
RedirectIfADAccount() {
  StartFunctionLog
  WriteToLogs "Redirecting folders to $MYHOMEDIR for $CurrentUSER"
  
  local retries=12
  
  # Retry loop for ensuring the remote home directory is mounted
  while [ $retries -gt 0 ]; do
    if [ -d "$MYHOMEDIR" ]; then
      WriteToLogs "$MYHOMEDIR is mounted"
      
      local folders=("Pictures" "Documents" "Downloads" "Desktop")
      for i in "${folders[@]}"; do
        # Ensure the folder exists in the remote directory
        mkdir -p "$MYHOMEDIR/$i"
        
        # Rebuild symlink safely
        rm -rf "/Users/$CurrentUSER/$i"
        ln -s "$MYHOMEDIR/$i" "/Users/$CurrentUSER/$i"
      done
      
      EndFunctionLog
      return 0 # Success
    else
      WriteToLogs "$MYHOMEDIR not available yet, waiting... ($retries retries left)"
      sleep 5
      ((retries--))
    fi
  done

  WriteToLogs "CRITICAL: Failed to detect $MYHOMEDIR. Aborting redirections to prevent local data corruption."
  EndFunctionLog
  return 1 # Failure
}

# Replace the default pinned Sidebar folders with new shortcuts.
PinRedirectedFolders() {
  StartFunctionLog
  
  local uid=$(id -u "$CurrentUSER")
  local mysides_bin="/usr/local/bin/mysides"

  if [[ ! -f "$mysides_bin" ]]; then
    WriteToLogs "Error: mysides not found at $mysides_bin."
    EndFunctionLog
    return 1
  fi

  # Give macOS a moment to settle the mount
  sleep 2

  local folders=("Desktop" "Documents" "Downloads" "Pictures")

  for name in "${folders[@]}"; do
    WriteToLogs "Updating sidebar favorite for $name"
    launchctl asuser "$uid" "$mysides_bin" remove "$name" >/dev/null 2>&1
    launchctl asuser "$uid" "$mysides_bin" add "$name" "file:///${MYHOMEDIR#/}/$name"
  done

  WriteToLogs "Updating local sidebar favorite for Music"
  launchctl asuser "$uid" "$mysides_bin" remove "Music" >/dev/null 2>&1
  launchctl asuser "$uid" "$mysides_bin" add "Music" "file:///Users/$CurrentUSER/Music"

  launchctl asuser "$uid" killall sharedfilelistd 2>/dev/null

  EndFunctionLog
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

LinkLibraryFolders() {
  StartFunctionLog
  
  # Ensure shared Minecraft directory exists
  mkdir -p "/Users/Shared/minecraft" || WriteToLogs "Failed to create directory /Users/Shared/minecraft"
  mkdir -p "/Users/$CurrentUSER/Library/Application Support/minecraft" || WriteToLogs "Failed to create directory /Users/$CurrentUSER/Library/Application Support/minecraft"
  
  local mineFolders=("assets" "versions")
  
  for m in "${mineFolders[@]}"; do
    if [ ! -d "/Users/Shared/minecraft/$m" ]; then
      WriteToLogs "Shared Minecraft $m not available, creating..."
      mkdir -p "/Users/Shared/minecraft/$m" || WriteToLogs "Failed to create directory /Users/Shared/minecraft/$m"
    else
      WriteToLogs "Shared Minecraft $m folder available"
    fi
    
    chown -R root:staff "/Users/Shared/minecraft/$m"
    chmod -R 777 "/Users/Shared/minecraft/$m"
    
    # Safely rebuild symlink
    WriteToLogs "Rebuilding Minecraft symlink for $m"
    if [ -L "/Users/$CurrentUSER/Library/Application Support/minecraft/$m" ]; then
      rm "/Users/$CurrentUSER/Library/Application Support/minecraft/$m"
    elif [ -d "/Users/$CurrentUSER/Library/Application Support/minecraft/$m" ]; then
      rm -r "/Users/$CurrentUSER/Library/Application Support/minecraft/$m"
    fi
    ln -s "/Users/Shared/minecraft/$m" "/Users/$CurrentUSER/Library/Application Support/minecraft/$m" || WriteToLogs "Failed to create symlink for $m"
  done
  
  local appSubfolders=("Dock" "iMovie")
  
  for x in "${appSubfolders[@]}"; do
    if [ ! -d "/Users/$CurrentUSER/Documents/Application Support/$x" ]; then
      WriteToLogs "$x not available, creating..."
      mkdir -p "/Users/$CurrentUSER/Documents/Application Support/$x" || WriteToLogs "Failed to create directory /Users/$CurrentUSER/Documents/Application Support/$x"
      chown "$CurrentUSER" "/Users/$CurrentUSER/Documents/Application Support/$x"
    else
      WriteToLogs "$x already available"
    fi
    
    # Safely rebuild symlink
    WriteToLogs "Rebuilding Application Support symlink for $x"
    if [ -L "/Users/$CurrentUSER/Library/Application Support/$x" ]; then
      rm "/Users/$CurrentUSER/Library/Application Support/$x"
    elif [ -d "/Users/$CurrentUSER/Library/Application Support/$x" ]; then
      rm -r "/Users/$CurrentUSER/Library/Application Support/$x"
    fi
    ln -s "/Users/$CurrentUSER/Documents/Application Support/$x" "/Users/$CurrentUSER/Library/Application Support/$x" || WriteToLogs "Failed to create symlink for $x"
  done
  
  EndFunctionLog
}


LinkTwineFolders() {
  StartFunctionLog

  local twine_target="/Users/$CurrentUSER/Twine"
  local twine_link="/Users/$CurrentUSER/Documents/Twine"

  # Ensure target exists
  if mkdir -p "$twine_target"; then
    WriteToLogs "Ensured directory exists: $twine_target"
  else
    WriteToLogs "Error: Failed to create directory $twine_target"
    EndFunctionLog
    return 1
  fi

  # Set ownership
  if chown "$CurrentUSER" "$twine_target"; then
    WriteToLogs "Set ownership of $twine_target to $CurrentUSER"
  else
    WriteToLogs "Warning: Failed to set ownership of $twine_target"
  fi

  # Check if link already exists and is correct
  if [ -L "$twine_link" ]; then
    current_target=$(readlink "$twine_link")
    if [ "$current_target" = "$twine_target" ]; then
      WriteToLogs "Symlink already in place: $twine_link → $twine_target"
      EndFunctionLog
      return 0
    else
      WriteToLogs "Removing incorrect symlink: $twine_link → $current_target"
      rm "$twine_link"
    fi
  elif [ -e "$twine_link" ]; then
    # Exists but is not a symlink (file or directory)
    WriteToLogs "Removing existing non-symlink item at $twine_link"
    rm -rf "$twine_link"
  fi

  # Create new symlink
  if ln -s "$twine_target" "$twine_link"; then
    WriteToLogs "Created symlink: $twine_link → $twine_target"
  else
    WriteToLogs "Error: Failed to create symlink at $twine_link"
    EndFunctionLog
    return 1
  fi

  EndFunctionLog
}

FixLibraryPerms() {
  StartFunctionLog
  
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
  
    adjust_permissions "/Applications/Minecraft.app" "777"
    adjust_permissions "/Users/Shared/minecraft" "777" "root" "wheel"
    adjust_permissions "/Users/$CurrentUSER/Library/Application Support/minecraft" "777"
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
  local status=0

  # Function to sync directories with checks
  sync_directory() {
    local src=$1
    local dest=$2
    local name=$3

    if [ -d "$src" ]; then
      rsync -avz "$src/" "$dest/"
      status=$?
      if [ $status -eq 0 ]; then
        WriteToLogs "Successfully synced $name from $src to $dest."
      else
        WriteToLogs "Error syncing $name from $src to $dest."
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
      rsync -avz "$srcBase/$file" "$destBase/"
    else
      WriteToLogs "File $srcBase/$file does not exist. Skipping."
    fi
  done

  # Sync GarageBand and Twine folders
  sync_directory "/Users/$CurrentUSER/Documents/GarageBand" "/Users/$CurrentUSER/Music/GarageBand" "GarageBand"
  sync_directory "/Users/$CurrentUSER/Documents/Sync/Twine" "/Users/$CurrentUSER/Twine" "Twine"

  EndFunctionLog
}

DeleteOldLocalHomes() {
  StartFunctionLog

  local base_dir="/Users"
  local size_threshold_kb=512000 # 500MB
  local now_epoch=$(date +%s)

  for dir in "$base_dir"/*; do
    # Skip symlinks and non-directories.
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    local username=$(basename "$dir")
    local age_days=""
    local age_source=""
    local age_epoch=""
    local age_timestamp=""

    WriteToLogs "Testing local home for $username at $dir."

    if [[ "$username" =~ ^(Shared|Guest|admin|helpdesk|jweston|\.localized)$ ]]; then
      WriteToLogs "Decision for $username: skipped protected/system/local account."
      continue
    fi

    if ! GetLocalHomeAge "$dir" "$now_epoch"; then
      WriteToLogs "Decision for $username: skipped; could not determine a reliable age for local home."
      continue
    fi

    age_days="$LOCAL_HOME_AGE_DAYS"
    age_source="$LOCAL_HOME_AGE_SOURCE"
    age_epoch="$LOCAL_HOME_AGE_EPOCH"
    age_timestamp=$(date -r "$age_epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")

    WriteToLogs "Age signal for $username: source=$age_source; timestamp=$age_timestamp; age=${age_days} days."

    if [ "$username" = "$CurrentUSER" ]; then
      WriteToLogs "Decision for $username: skipped active console user; login stamp will be updated after cleanup."
      continue
    fi

    # If the user has not logged in for 120 days, wipe the whole local home.
    if [ "$age_days" -ge "$OLD_AGE_THRESHOLD" ]; then
      WriteToLogs "Decision for $username: delete stale local home; age ${age_days} days meets $OLD_AGE_THRESHOLD day threshold."
      if rm -rf "$dir"; then
        if [ -e "$dir" ]; then
          WriteToLogs "ERROR for $username: rm completed but $dir still exists."
        else
          WriteToLogs "Result for $username: deleted local home $dir."
        fi
      else
        WriteToLogs "ERROR for $username: failed to delete local home $dir."
      fi
      continue
    fi

    if [ "$age_days" -lt "$AGE_THRESHOLD" ]; then
      WriteToLogs "Decision for $username: no cleanup; age ${age_days} days is younger than $AGE_THRESHOLD day threshold."
      continue
    fi

    WriteToLogs "Decision for $username: inspect high-size local content; age ${age_days} days is between $AGE_THRESHOLD and $OLD_AGE_THRESHOLD days."
    CleanLargeLocalContent "$username" "$dir" "$size_threshold_kb"
  done

  EndFunctionLog
}

GetLocalHomeAge() {
  local dir="$1"
  local now_epoch="$2"
  local marker="$dir/$LOCAL_LOGIN_STAMP_REL"
  local newest_epoch=""
  local newest_source=""

  LOCAL_HOME_AGE_DAYS=""
  LOCAL_HOME_AGE_SOURCE=""
  LOCAL_HOME_AGE_EPOCH=""

  if [ -f "$marker" ]; then
    newest_epoch=$(stat -f "%m" "$marker" 2>/dev/null)
    if [[ "$newest_epoch" =~ ^[0-9]+$ ]]; then
      LOCAL_HOME_AGE_DAYS=$(( (now_epoch - newest_epoch) / 86400 ))
      [ "$LOCAL_HOME_AGE_DAYS" -lt 0 ] && LOCAL_HOME_AGE_DAYS=0
      LOCAL_HOME_AGE_SOURCE="login-stamp:$marker"
      LOCAL_HOME_AGE_EPOCH="$newest_epoch"
      return 0
    fi
    WriteToLogs "Warning: login stamp exists but could not be read: $marker"
  else
    WriteToLogs "No login stamp found for $dir; using fallback age signal."
  fi

  local fallback_paths=(
    "$dir"
    "$dir/Library"
    "$dir/Library/Preferences"
    "$dir/Library/Application Support"
    "$dir/Library/Caches"
    "$dir/Music"
    "$dir/Music/GarageBand"
    "$dir/Twine"
  )

  for path in "${fallback_paths[@]}"; do
    [ -e "$path" ] || continue
    [ -L "$path" ] && continue

    local path_epoch=$(stat -f "%m" "$path" 2>/dev/null)
    if [[ "$path_epoch" =~ ^[0-9]+$ ]] && { [ -z "$newest_epoch" ] || [ "$path_epoch" -gt "$newest_epoch" ]; }; then
      newest_epoch="$path_epoch"
      newest_source="$path"
    fi
  done

  if [ -z "$newest_epoch" ]; then
    return 1
  fi

  LOCAL_HOME_AGE_DAYS=$(( (now_epoch - newest_epoch) / 86400 ))
  [ "$LOCAL_HOME_AGE_DAYS" -lt 0 ] && LOCAL_HOME_AGE_DAYS=0
  LOCAL_HOME_AGE_SOURCE="fallback-newest-known-path:$newest_source"
  LOCAL_HOME_AGE_EPOCH="$newest_epoch"
  return 0
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
    if [ ! -d "$target" ]; then
      WriteToLogs "Result for $username: cleanup target missing, skipped: $target"
      continue
    fi

    local folder_size_kb=$(du -sk "$target" 2>/dev/null | cut -f1)
    if ! [[ "$folder_size_kb" =~ ^[0-9]+$ ]]; then
      WriteToLogs "ERROR for $username: could not determine size for $target; skipped."
      continue
    fi

    local folder_size_mb=$(( folder_size_kb / 1024 ))
    local threshold_mb=$(( size_threshold_kb / 1024 ))

    if [ "$folder_size_kb" -gt "$size_threshold_kb" ]; then
      WriteToLogs "Decision for $username: delete large local content $target (${folder_size_mb}MB > ${threshold_mb}MB)."
      if rm -rf "$target"; then
        if [ -e "$target" ]; then
          WriteToLogs "ERROR for $username: rm completed but $target still exists."
        else
          WriteToLogs "Result for $username: deleted large local content $target."
        fi
      else
        WriteToLogs "ERROR for $username: failed to delete large local content $target."
      fi
    else
      WriteToLogs "Result for $username: kept $target (${folder_size_mb}MB <= ${threshold_mb}MB)."
    fi
  done
}

UpdateCurrentLoginStamp() {
  StartFunctionLog

  local marker_dir="/Users/$CurrentUSER/$(dirname "$LOCAL_LOGIN_STAMP_REL")"
  local marker_path="/Users/$CurrentUSER/$LOCAL_LOGIN_STAMP_REL"

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
  WriteToLogs "Login script started (script version $SCRIPT_VERSION)"
  WriteToLogs "Current User: $CurrentUSER"
  
  touch "/Users/$CurrentUSER/Library/Application Support/com.gvsd.LogonScriptRun.plist"
  chown $CurrentUSER "/Users/$CurrentUSER/Library/Preferences/com.apple.dock.plist"

  CheckIfADAccount
  
  if [ $AD = "1" ]; then
    CheckADUserType
  else
    WriteToLogs "Current user is not an AD account."
    exit 1
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
    -accessory_view_payload "${PROG_ACCESSORY_PAYLOAD}" < "/tmp/${PIPE_NAME}" &
  
  # Store the Notifier UI process ID so we can kill it later.
  Notifier_Process=$(pgrep "IBM Notifier")
  
  if [ "$ADUser" = "Student" ] || [ "$ADUser" = "Staff" ]; then
    CheckFolderPath "$ADUser"
  else
    WriteToLogs "Unknown ADUser value: $ADUser" 
  fi
    
  WriteToLogs "Home Folder is $MYHOMEDIR"
  
  if RedirectIfADAccount; then
    PinRedirectedFolders
    CreateDocumentLibraryFolders
    LinkLibraryFolders
    LinkTwineFolders
    FixLibraryPerms
    SyncFiles
    WriteToLogs "Login script complete."
  else
    WriteToLogs "ERROR: Setup aborted due to missing network home."
  fi
  
  # Tell the progress UI to close, and clean up.
  echo -n "/percent 100" >&3
  exec 3>&-
  rm -f "/tmp/${PIPE_NAME}"
  
  # Fully kill the Notifier UI.
  if [ -n "$Notifier_Process" ] && kill -0 "$Notifier_Process" 2>/dev/null; then
      kill -TERM "$Notifier_Process"
  else
      WriteToLogs "No process found with ID $Notifier_Process"
  fi
}

# Do the main sequence, wrapped by the progress UI.
# Delete the stale local homes after the UI has closed, as we don't need to watch it.
display_progress
DeleteOldLocalHomes
UpdateCurrentLoginStamp

exit 0
