﻿#!/bin/bash

####################################################################################
# Script to handle folder redirections and permissions for student & staff logins. #
####################################################################################

# Set global variables.
SCRIPT_VERSION="2025-05-26-1021"
CurrentUSER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /Loginwindow/ { print $3 }' )
SYNCLOG="/tmp/LibrarySync.log"
# Age threshold for local home deletion
AGE_THRESHOLD=15

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
  
  local mounted=1
  local retries=12  # Max retries for mount check
  local folders=(
    "Pictures"
    "Documents"
    "Downloads"
    "Desktop"
  )

  # Retry loop for ensuring the remote home directory is mounted
  while [ $mounted -gt 0 ]; do
    if [ -d "$MYHOMEDIR" ]; then
      WriteToLogs "$MYHOMEDIR is mounted"
      mounted=0
      
      for i in "${folders[@]}"; do
        # Ensure the folder exists in the remote directory
        if [ -d "$MYHOMEDIR/$i" ]; then
          WriteToLogs "$i available"
        else
          WriteToLogs "$i not available, creating..."
          mkdir -p "$MYHOMEDIR/$i"
          local status=$?
          if [ $status -eq 0 ]; then
            WriteToLogs "$MYHOMEDIR/$i created successfully"
          elif [ $status -eq 2 ]; then
            WriteToLogs "Failed to create $MYHOMEDIR/$i due to insufficient permissions"
          else
            WriteToLogs "$MYHOMEDIR/$i already exists"
          fi
        fi

        # Handle existing symlinks or directories
        WriteToLogs "Rebuilding symlink for $i"
        if [ -L "/Users/$CurrentUSER/$i" ]; then
          rm "/Users/$CurrentUSER/$i"
        elif [ -d "/Users/$CurrentUSER/$i" ]; then
          rm -r "/Users/$CurrentUSER/$i"
        elif [ -e "/Users/$CurrentUSER/$i" ]; then
          rm "/Users/$CurrentUSER/$i"
        fi

        # Create new symlink
        ln -s "$MYHOMEDIR/$i" "/Users/$CurrentUSER/$i"
      done

    else
      WriteToLogs "$MYHOMEDIR not available yet, waiting..."
      sleep 5
      retries=$((retries - 1))
      if [ $retries -le 0 ]; then
        WriteToLogs "Failed to detect $MYHOMEDIR after multiple retries. Exiting."
        EndFunctionLog
        return 1
      fi
    fi
  done

  EndFunctionLog
}

# Replace the default pinned Sidebar folders with new shortcuts.
PinRedirectedFolders()  {
  StartFunctionLog
  
  function remove_mysides() {
    local uid="$1"
    shift  # Shift arguments so $2 becomes $1, $3 becomes $2, etc.
    for name in "$@"; do
      launchctl asuser "$uid" /usr/local/bin/mysides remove "$name"
    done
  }
  
  function add_mysides() {
    local uid="$1"
    shift  # Shift arguments so $2 becomes $1, $3 becomes $2, etc.
    for name in "$@"; do
      launchctl asuser "$uid" /usr/local/bin/mysides add "$name" file:///Users/$CurrentUSER/$name
    done
  }
  
  local uid=$(id -u "$CurrentUSER")
  
  # Remove default pinned Sidebar folders
  remove_mysides $uid "Desktop" "Downloads" "Documents" "Pictures" "Music" "Library"
  
  # Pin new Sidebar folders
  add_mysides $uid "Desktop" "Downloads" "Documents" "Pictures" "Music" "Library"
    
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
      if [ $? -eq 0 ]; then
        WriteToLogs "Successfully synced $file from $srcBase to $destBase."
      else
        WriteToLogs "Error syncing $file from $srcBase to $destBase."
      fi
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
  # This function frees up space on the client by deleting selected large folders
  # in users' local home directories that haven't been modified in AGE_THRESHOLD days.
  # It does not touch files in the users' actual home directories on the network share.

  StartFunctionLog

  BASE_DIR="/Users"
  SIZE_THRESHOLD_KB=512000  # 500MB in kb

  for dir in "$BASE_DIR"/*; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue

    username=$(basename "$dir")

    case "$username" in
      "Shared"|".localized"|"admin")
        continue
        ;;
    esac

    if [[ "$(realpath "$dir")" == "$BASE_DIR"/* ]] && [ "$(find "$dir" -maxdepth 0 -type d -not -mtime -$AGE_THRESHOLD | wc -l)" -gt 0 ]; then
      WriteToLogs "Cleaning up selected folders in $username's local home."

      # Paths to delete inside the user's home
      folders_to_delete=(
        "$dir/Library/Application Support/minecraft/saves"
        "$dir/Music/GarageBand"
      )

      for target in "${folders_to_delete[@]}"; do
        if [ -d "$target" ]; then
          rm_output=$(rm -rf "$target" 2>&1)
          if [ $? -eq 0 ]; then
            WriteToLogs "Deleted $target."
          else
            WriteToLogs "Error deleting $target: $rm_output"
          fi
        else
          WriteToLogs "Skipped $target (not found)."
        fi
      done

      # Also delete folders in ~/Library over 500MB
      LIBRARY_DIR="$dir/Library"
      if [ -d "$LIBRARY_DIR" ]; then
        find "$LIBRARY_DIR" -mindepth 1 -maxdepth 1 -type d | while read -r subdir; do
          folder_size_kb=$(du -sk "$subdir" | awk '{print $1}')
          if [ "$folder_size_kb" -gt "$SIZE_THRESHOLD_KB" ]; then
            if rm -rf "$subdir"; then
              WriteToLogs "Deleted large folder $subdir (${folder_size_kb}KB)."
            else
              WriteToLogs "Error deleting large folder $subdir."
            fi
          fi
        done
      fi

    else
      WriteToLogs "Skipping $dir. Either recently modified or not valid."
    fi
  done

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
  
  if [ "$ADUser" = "Student" ] || [ "$ADUser" = "Staff" ]; then
    if [ ! -d "$MYHOMEDIR/Library/Preferences" ]; then
      CreateHomeLibraryFolders
    else
      WriteToLogs "Home Library exists already"
    fi
  fi
  
  RedirectIfADAccount
  PinRedirectedFolders
  CreateDocumentLibraryFolders
  LinkLibraryFolders
  LinkTwineFolders
  FixLibraryPerms
  SyncFiles
  
  WriteToLogs "Login script complete."
  
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

exit 0
