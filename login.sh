#!/bin/bash

####################################################################################
# Script to handle folder redirections and permissions for student & staff logins. #
####################################################################################

# Set global variables.
SCRIPT_VERSION="2024-02-28-1332"
CurrentUSER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /Loginwindow/ { print $3 }' )
SYNCLOG="/tmp/LibrarySync.log"

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
  WriteToLogs "Started ${FUNCNAME[1]} function" # FUNCNAME[1] is the name of the calling function
  echo -n "/bottom_message Starting ${FUNCNAME[1]}..." >&3
}

# Log the end of a function and its total duration.
EndFunctionLog() {
  local end_time=$(date +%s)
  local duration=$((end_time - FUNC_START_TIME))
  WriteToLogs "### Finished ${FUNCNAME[1]} function in $duration seconds"
}

# Runs a command as the currently logged-in user.
RunAsUser() {  
  if [ "$CurrentUSER" != "loginwindow" ]; then
    launchctl asuser "$(id -u "$CurrentUSER")" sudo -u "$CurrentUSER" "$@"
  else
    WriteToLogs "No user logged in." >&2
    return 1
  fi
}

# Batch folder creation and permission setting.
# Pass a directory and a userID to this.
CreateFolderAndSetPermissions() {
  local dir_path="$1"
  local owner="$2"
  
  mkdir -p "$dir_path"
  if [ $? -eq 0 ]; then
    WriteToLogs "$dir_path created successfully"
  else
    if [ $? -eq 2 ]; then
      WriteToLogs "Failed to create $dir_path due to insufficient permissions"
    else
      WriteToLogs "$dir_path already exists"
    fi
  fi
  chown "$owner" "$dir_path"
  chmod -R 700 "$dir_path"
}

# Check if the current user is an AD account.
# Sets the global $AD variable to 1 for AD, 0 for local.
CheckIfADAccount() {
  local loggedInUser=$(stat -f%Su /dev/console)
  local accountCheck=$(dscl . read /Users/$loggedInUser OriginalAuthenticationAuthority 2>/dev/null)

  if [ "$accountCheck" != "" ]; then
    WriteToLogs "User $loggedInUser is an AD account"
    AD=1
  else
    WriteToLogs "User $loggedInUser is a local account"
    AD=0
  fi
}

# Check if the current user is a student or staff.
# Sets the global $ADUser variable to "Student" or "Staff".
CheckADUserType() {
  local accountCheck=$(dscl . read /Users/$CurrentUSER OriginalAuthenticationAuthority 2>/dev/null)
  
  if [ "$accountCheck" != "" ] && [[ $CurrentUSER =~ ^[0-9] ]]; then
    WriteToLogs "User $CurrentUSER is a student account"
    ADUser='Student'
  else
    WriteToLogs "User $CurrentUSER is a staff account"
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
RedirectIfADAccount()  {
  StartFunctionLog
  WriteToLogs "Redirecting folders to $MYHOMEDIR for $CurrentUSER"
  
  local mounted=1
  local folders=(
    "Pictures"
    "Documents"
    "Downloads"
    "Desktop"
  )
  
  # This has a try/sleep cycle to ensure that the remote home directory has finished mounting.
  while [ $mounted -gt 0 ]; do
    if [ -d "$MYHOMEDIR" ]; then
      WriteToLogs "$MYHOMEDIR is mounted"
      
      for i in "${folders[@]}"; do
        if [ -d "$MYHOMEDIR/$i" ]; then
          WriteToLogs "$i available"
        else
          WriteToLogs "$i not available, creating..."
          mkdir -p "$MYHOMEDIR/$i"
          if [ $? -eq 0 ]; then
            WriteToLogs "$MYHOMEDIR/$i created successfully"
          else
            if [ $? -eq 2 ]; then
              WriteToLogs "Failed to create $MYHOMEDIR/$i due to insufficient permissions"
            else
              WriteToLogs "$MYHOMEDIR/$i already exists"
            fi
          fi
        fi
        
        WriteToLogs "Rebuilding symlink for $i"
        
        if [ -L "/Users/$CurrentUSER/$i" ]; then
          # If it's a symbolic link, delete the link only
          rm "/Users/$CurrentUSER/$i"
        elif [ -d "/Users/$CurrentUSER/$i" ]; then
          # If it's a directory, recursively delete it and its contents
          rm -r -P "/Users/$CurrentUSER/$i"
        fi
        ln -s "$MYHOMEDIR/$i" "/Users/$CurrentUSER/"
      done
      
      mounted=`expr $mounted - 1`
      
    else
      WriteToLogs "$MYHOMEDIR not available yet, waiting..."
      sleep 5
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
  )
  
  for dir in "${directories[@]}"; do
    CreateFolderAndSetPermissions "/Users/$CurrentUSER/$dir" "$CurrentUSER"
  done

  EndFunctionLog
}

PreStageUnlinkedAppFolders() {
  StartFunctionLog
  
  local directories=(
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
  
  # Symlink Minecraft folders to machine local shared
  mkdir -p "/Users/Shared/minecraft" || WriteToLogs "Failed to create directory /Users/Shared/minecraft"
  mkdir -p "/Users/$CurrentUSER/Library/Application Support/minecraft"  || WriteToLogs "Failed to create directory /Users/$CurrentUSER/Library/Application Support/minecraft"
  
  local mineFolders=(
    "assets"
    "versions"
  )
  
  for m in "${mineFolders[@]}"; do
    if [ -d "/Users/Shared/minecraft/$m" ]; then
      WriteToLogs "Shared Minecraft $m folder available"
    else
      WriteToLogs "Shared Minecraft $m not available, creating..."
      mkdir -p "/Users/Shared/minecraft/$m" || WriteToLogs "Failed to create directory /Users/Shared/minecraft/$m"
    fi
    
    chown -R root:wheel "/Users/Shared/minecraft/$m"
    chmod -R 777 "/Users/Shared/minecraft/$m"
    
    WriteToLogs "Rebuilding Minecraft symlinks."
    rm -R "/Users/$CurrentUSER/Library/Application Support/minecraft/$m"
    ln -s "/Users/Shared/minecraft/$m" "/Users/$CurrentUSER/Library/Application Support/minecraft/"
  done
    
  local appSubfolders=(
    "Dock"
    "iMovie"
  )
  
  for x in "${appSubfolders[@]}"; do
    if [ -d "/Users/$CurrentUSER/Documents/Application Support/$x" ]; then
      WriteToLogs "$x already available"
    else
      WriteToLogs "$x not available, creating..."
      mkdir -p "/Users/$CurrentUSER/Documents/Application Support/$x" || WriteToLogs "Failed to create directory /Users/$CurrentUSER/Documents/Application Support/$x"
      chown $CurrentUSER "/Users/$CurrentUSER/Documents/Application Support/$x"
    fi
    
    WriteToLogs "Rebuilding Application Support symlinks."
    rm -R "/Users/$CurrentUSER/Library/Application Support/$x"
    ln -s "/Users/$CurrentUSER/Documents/Application Support/$x" "/Users/$CurrentUSER/Library/Application Support/"
  done 
  
  EndFunctionLog
}

LinkTwineFolders() {
  StartFunctionLog
  
  mkdir -p "/Users/$CurrentUSER/Twine" || WriteToLogs "Failed to create directory /Users/$CurrentUSER/Twine"
  chown $CurrentUSER "/Users/$CurrentUSER/Twine"
  
  WriteToLogs "Rebuilding Twine symlink."
  rm -R "/Users/$CurrentUSER/Documents/Twine"
  ln -s "/Users/$CurrentUSER/Twine" "/Users/$CurrentUSER/Documents/"
  
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

CopyRoamingAppFiles() {
  StartFunctionLog
  
  local srcBase="/Users/$CurrentUSER/Documents/Application Support/minecraft"
  local destBase="/Users/$CurrentUSER/Library/Application Support/minecraft"
  
  # Sync the Minecraft saves directory
  rsync -avz "$srcBase/saves/" "$destBase/saves/"
  
  # Sync the Minecraft curseforge directory
  rsync -avz "$srcBase/curseforge/" "$destBase/curseforge/"
  
  # Sync individual Minecraft settings files
  local files=(
    "launcher_accounts.json"
    "launcher_msa_credentials.bin"
    "options.txt"
  )
  for file in "${files[@]}"; do
    rsync -avz "$srcBase/$file" "$destBase/"
  done
  
  # Sync GarageBand and Twine folders
  rsync -avz "/Users/$CurrentUSER/Documents/GarageBand/" "/Users/$CurrentUSER/Music/GarageBand/"  
  rsync -avz "/Users/$CurrentUSER/Documents/Sync/Twine/" "/Users/$CurrentUSER/Twine/"
  
  EndFunctionLog
}

DeleteOldLocalHomes() {
  StartFunctionLog
  
  # Define the age threshold (in days)
  AGE_THRESHOLD=30
  
  # Loop through each directory in /Users
  for dir in /Users/*; do
    # Skip if it's not a directory
    [ -d "$dir" ] || continue
  
    # Extract username from directory path
    username=$(basename "$dir")
  
    # Skip certain accounts
    case "$username" in
      "Shared"|".localized"|"admin"|"helpdesk")
        continue
        ;;
    esac
  
    # Delete if the directory was modified more than the threshold ago
    if [ $(find "$dir" -maxdepth 0 -type d -not -mtime -$AGE_THRESHOLD | wc -l) -gt 0 ]; then
      WriteToLogs "Deleting local home for $username, not modified in last $AGE_THRESHOLD days."
      rm -rf "$dir"
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
  chown $CurrentUser "/Users/$CurrentUSER/Library/Preferences/com.apple.dock.plist"

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
  PreStageUnlinkedAppFolders
  LinkLibraryFolders
  LinkTwineFolders
  FixLibraryPerms
  CopyRoamingAppFiles
  
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