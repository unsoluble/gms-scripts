#!/bin/bash

####################################################################################
# Script to handle folder redirections and permissions for student & staff logins. #
####################################################################################

# Set global variables.
CurrentUSER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /Loginwindow/ { print $3 }' )
SYNCLOG="/tmp/LibrarySync.log"

# Notifier UI paths.
APP_PATH="/Applications/IBM Notifier.app/Contents/MacOS/IBM Notifier"

# Variables for the progress dialog.
PROG_BAR_TITLE="Logging In"
PROG_TITLE="Syncing your files! Your stuff will be ready when this finishes."
PROG_TIMEOUT_SECONDS=300
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
  
  if [ ! -d "$dir_path" ]; then
    mkdir -p "$dir_path"
    chown "$owner" "$dir_path"
    chmod -R 777 "$dir_path"
  fi
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

  if [ -d /Volumes/$CurrentUSER ]; then
    MYHOMEDIR=/Volumes/$CurrentUSER
  fi
  
  local homeDirUpper="/Volumes/${userType}Home\$/"
  local homeDirLower="/Volumes/${userType}home\$/"

  if [ -d "$homeDirUpper$CurrentUSER" ]; then 
    MYHOMEDIR="${homeDirUpper}${CurrentUSER}"
  else
    MYHOMEDIR="${homeDirLower}${CurrentUSER}"
  fi
}

# Redirect folders in the local home directory to the remote home.
RedirectIfADAccount()  {
  local start_time=$(date +%s)  # Capture start time in seconds
  WriteToLogs "Started ${FUNCNAME[0]} function"
  # Write the current function name to the UI progress window as well.
  echo -n "/bottom_message ${FUNCNAME[0]}" >&3
  
  # If the plist file already exists, this should already be complete, so is skipped.
  if [ ! -f "/Users/$CurrentUSER/Library/Application Support/com.gvsd.RedirectedFolders.plist" ]; then
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
        WriteToLogs "$MYHOMEDIR exists"
        
        for i in "${folders[@]}"; do
          if [ -d "$MYHOMEDIR/$i" ]; then
            WriteToLogs "$i available"
          else
            WriteToLogs "$i not available, creating..."
            mkdir -p "$MYHOMEDIR/$i"
          fi
          
          WriteToLogs "Testing symlinks"
          
          if [ ! -L /Users/$CurrentUSER/$i ]; then
            WriteToLogs "$i folder not linked, now linking"
            chmod -R 777 /Users/$CurrentUSER/$i
            rm -R /Users/$CurrentUSER/$i
            ln -s "$MYHOMEDIR/$i" /Users/$CurrentUSER/
          else
            WriteToLogs "$i was already linked"
          fi
        done
        
        mounted=`expr $mounted - 1`
        
      else
        WriteToLogs "$MYHOMEDIR not available yet, waiting..."
        sleep 5
      fi
    done
    
    # Generate a plist to indicate this process is complete.
    touch "/Users/$CurrentUSER/Library/Application Support/com.gvsd.RedirectedFolders.plist"
    chown $CurrentUSER "/Users/$CurrentUSER/Library/Application Support/com.gvsd.RedirectedFolders.plist"
    chmod 777 "/Users/$CurrentUSER/Library/Application Support/com.gvsd.RedirectedFolders.plist"
  fi
  
  local end_time=$(date +%s)  # Capture end time in seconds
  local duration=$((end_time - start_time))  # Calculate duration
  WriteToLogs "### Finished ${FUNCNAME[0]} function in $duration seconds"
}

# Replace the default pinned Sidebar folders with new shortcuts.
PinRedirectedFolders()  {
  local start_time=$(date +%s)  # Capture start time in seconds
  WriteToLogs "Started ${FUNCNAME[0]} function"
  echo -n "/bottom_message ${FUNCNAME[0]}" >&3
  
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
  
  # Generate a plist to indicate this process is complete
  touch "/Users/$CurrentUSER/Library/Application Support/com.gvsd.PinFolders.plist"
  chown $CurrentUSER "/Users/$CurrentUSER/Library/Application Support/com.gvsd.PinFolders.plist"
  chmod 755 "/Users/$CurrentUSER/Library/Application Support/com.gvsd.PinFolders.plist"
  
  local end_time=$(date +%s)  # Capture end time in seconds
  local duration=$((end_time - start_time))  # Calculate duration
  WriteToLogs "### Finished ${FUNCNAME[0]} function in $duration seconds"
}

CreateHomeLibraryFolders()  {
  local start_time=$(date +%s)  # Capture start time in seconds
  WriteToLogs "Started ${FUNCNAME[0]} function"
  echo -n "/bottom_message ${FUNCNAME[0]}" >&3
  
  # If the SyncedPreferences folder exists, this creation routine should already be complete.
  if [ -d "$MYHOMEDIR/Library/SyncedPreferences" ]; then
    WriteToLogs "Library available"
    
    # Generate plists to indicate this process is complete
    touch "$MYHOMEDIR/Library/Preferences/com.gvsd.HomeLibraryExists.plist" 
    touch "/Users/$CurrentUSER/Library/Preferences/com.gvsd.HomeLibraryExists.plist" 
  else
    # This chmod seems excessive here; removing for now
    # chmod -R 777 "$MYHOMEDIR"
    
    # First create the root Library folder
    if [ ! -d "$MYHOMEDIR/Library" ]; then
      mkdir -p "$MYHOMEDIR/Library"
      chown $CurrentUSER "$MYHOMEDIR/Library"
    fi
    
    # Set of Library folders to create
    local directories=(
      "Library/Preferences"
      "Library/PreferencePanes"
      "Library/Safari"
      "Library/Saved Application State"
      "Library/SyncedPreferences"
    )
    
    for dir in "${directories[@]}"; do
      CreateFolderAndSetPermissions "$MYHOMEDIR/$dir" "$CurrentUSER"
    done
    
    # Generate plists to indicate this process is complete
    touch "$MYHOMEDIR/Library/Preferences/com.gvsd.HomeLibraryExists.plist" 
    touch "/Users/$CurrentUSER/Library/Preferences/com.gvsd.HomeLibraryExists.plist" 
  fi 
  
  local end_time=$(date +%s)  # Capture end time in seconds
  local duration=$((end_time - start_time))  # Calculate duration
  WriteToLogs "### Finished ${FUNCNAME[0]} function in $duration seconds"
}

CreateDocumentLibraryFolders() {
  local start_time=$(date +%s)  # Capture start time in seconds
  WriteToLogs "Started ${FUNCNAME[0]} function"
  echo -n "/bottom_message ${FUNCNAME[0]}" >&3
  
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

  local end_time=$(date +%s)  # Capture end time in seconds
  local duration=$((end_time - start_time))  # Calculate duration
  WriteToLogs "### Finished ${FUNCNAME[0]} function in $duration seconds"
}

PreStageUnlinkedAppFolders() {
  local start_time=$(date +%s)  # Capture start time in seconds
  WriteToLogs "Started ${FUNCNAME[0]} function"
  echo -n "/bottom_message ${FUNCNAME[0]}" >&3
  
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
  
  local end_time=$(date +%s)  # Capture end time in seconds
  local duration=$((end_time - start_time))  # Calculate duration
  WriteToLogs "### Finished ${FUNCNAME[0]} function in $duration seconds"
}

LinkLibraryFolders() {
  local start_time=$(date +%s)  # Capture start time in seconds
  WriteToLogs "Started ${FUNCNAME[0]} function"
  echo -n "/bottom_message ${FUNCNAME[0]}" >&3
  
  # Symlink Minecraft folders to machine local shared
  mkdir -p "/Users/Shared/minecraft"
  mkdir -p "/Users/$CurrentUSER/Library/Application Support/minecraft"
  
  local mineFolders=(
    "assets"
    "versions"
  )
  
  for (( m=0; m < ${#mineFolders[@]}; m++ )); do
    if [ -d "/Users/Shared/minecraft/${mineFolders[m]}" ]; then
      WriteToLogs "Shared Minecraft ${mineFolders[m]} folder available"
    else
      WriteToLogs "Shared Minecraft ${mineFolders[m]} not available, creating..."
      mkdir -p "/Users/Shared/minecraft/${mineFolders[m]}"
    fi
    
    chown -R root:wheel "/Users/Shared/minecraft/${mineFolders[m]}"
    chmod -R 777 "/Users/Shared/minecraft/${mineFolders[m]}"
    
    if [ ! -L "/Users/$CurrentUSER/Library/Application Support/minecraft/${mineFolders[m]}" ]; then
      WriteToLogs "Minecraft ${mineFolders[m]} subfolder is not linked, now linking..."
      rm -R "/Users/$CurrentUSER/Library/Application Support/minecraft/${mineFolders[m]}"
      ln -s "/Users/Shared/minecraft/${mineFolders[m]}" "/Users/$CurrentUSER/Library/Application Support/minecraft/"
    else
      WriteToLogs "Minecraft ${mineFolders[m]} subfolder already linked"
    fi
  done
  
  # Symlink Application Sub Folders
  WriteToLogs "Creating Application Support subfolder symlinks"
  
  local appSubfolders=(
    "Dock"
    "iMovie"
  )
  
  for x in "${appSubfolders[@]}"; do
    if [ -d "/Users/$CurrentUSER/Documents/Application Support/$x" ]; then
      WriteToLogs "$x already available"
    else
      WriteToLogs "$x not available, creating..."
      mkdir -p "/Users/$CurrentUSER/Documents/Application Support/$x"
      chmod -R 777 "/Users/$CurrentUSER/Documents/Application Support/$x"
    fi
    
    WriteToLogs "Testing symlinks"
    
    if [ ! -L "/Users/$CurrentUSER/Library/Application Support/$x" ]; then
      WriteToLogs "Application Support subfolder $x is not linked, now linking..."
      rm -Rf "/Users/$CurrentUSER/Library/Application Support/$x"
      ln -s "/Users/$CurrentUSER/Documents/Application Support/$x" "/Users/$CurrentUSER/Library/Application Support/"
    else
      WriteToLogs "$x subfolder already linked"
    fi
  done 
  
  local end_time=$(date +%s)  # Capture end time in seconds
  local duration=$((end_time - start_time))  # Calculate duration
  WriteToLogs "### Finished ${FUNCNAME[0]} function in $duration seconds"
}

LinkTwineFolders() {
  local start_time=$(date +%s)  # Capture start time in seconds
  WriteToLogs "Started ${FUNCNAME[0]} function"
  echo -n "/bottom_message ${FUNCNAME[0]}" >&3
  
  mkdir -p "/Users/$CurrentUSER/Twine"
  chmod -R 777 "/Users/$CurrentUSER/Twine"
  
  if [ ! -L "/Users/$CurrentUSER/Documents/Twine" ]; then
    WriteToLogs "Twine is not linked, now linking..."
    rm -Rf "/Users/$CurrentUSER/Documents/Twine"
    ln -s "/Users/$CurrentUSER/Twine" "/Users/$CurrentUSER/Documents/"
  else
    WriteToLogs "Twine subfolder already linked"
  fi
  
  local end_time=$(date +%s)  # Capture end time in seconds
  local duration=$((end_time - start_time))  # Calculate duration
  WriteToLogs "### Finished ${FUNCNAME[0]} function in $duration seconds"
}

FixLibraryPerms() {
  local start_time=$(date +%s)  # Capture start time in seconds
  WriteToLogs "Started ${FUNCNAME[0]} function"
  echo -n "/bottom_message ${FUNCNAME[0]}" >&3
  
  adjust_permissions() {
    local dir_path="$1"
    local desired_perm="$2"
    local owner="$3"
    local group="$4"

    if [ ! "$(stat -f '%A' "$dir_path")" = "$desired_perm" ]; then
      [ -n "$owner" ] && chown -R "$owner:$group" "$dir_path"
      chmod -R "$desired_perm" "$dir_path"
      WriteToLogs "Set permissions for $dir_path"
    fi
  }
  
    adjust_permissions "/Applications/Minecraft.app" "777"
    adjust_permissions "/Users/$CurrentUSER/Library/Application Support/minecraft" "777"
    adjust_permissions "/Users/$CurrentUSER/Documents/Application Support/minecraft" "777"
    adjust_permissions "/Users/$CurrentUSER/Documents/Application Support/minecraft/saves" "777" "$CurrentUSER"
    adjust_permissions "/Users/Shared/minecraft/assets" "777" "root" "wheel"
    adjust_permissions "/Users/$CurrentUSER/Music/Audio Music Apps" "777"
    adjust_permissions "/Users/$CurrentUSER/Music/GarageBand" "777"
    adjust_permissions "/Users/$CurrentUSER/Library/Application Support/Google" "777"
  
  local end_time=$(date +%s)  # Capture end time in seconds
  local duration=$((end_time - start_time))  # Calculate duration
  WriteToLogs "### Finished ${FUNCNAME[0]} function in $duration seconds"
}

CopyRoamingAppFiles() {
  local start_time=$(date +%s)  # Capture start time in seconds
  WriteToLogs "Started ${FUNCNAME[0]} function"
  echo -n "/bottom_message ${FUNCNAME[0]}" >&3
  
  local srcBase="/Users/$CurrentUSER/Documents/Application Support/minecraft"
  local destBase="/Users/$CurrentUSER/Library/Application Support/minecraft"
  
  # Sync the Minecraft saves directory
  rsync -avz "$srcBase/saves/" "$destBase/saves/"
  
  # Sync individual Minecraft settings files
  local files=(
    "launcher_accounts.json"
    "launcher_msa_credentials.bin"
    "options.txt"
  )
  for file in "${files[@]}"; do
    rsync -avz "$srcBase/$file" "$destBase/"
  done
    
  chmod -R 777 "/Users/Shared/minecraft"
  
  # Sync GarageBand and Twine folders
  rsync -avz "/Users/$CurrentUSER/Documents/GarageBand/" "/Users/$CurrentUSER/Music/GarageBand/"  
  rsync -avz "/Users/$CurrentUSER/Documents/Sync/Twine/" "/Users/$CurrentUSER/Twine/"
  
  local end_time=$(date +%s)  # Capture end time in seconds
  local duration=$((end_time - start_time))  # Calculate duration
  WriteToLogs "### Finished ${FUNCNAME[0]} function in $duration seconds"
}

SyncHomeLibraryToLocal() {
  local start_time=$(date +%s)  # Capture start time in seconds
  WriteToLogs "Started ${FUNCNAME[0]} function"
  echo -n "/bottom_message ${FUNCNAME[0]}" >&3
  
  if [ -f "$MYHOMEDIR/Library/Preferences/com.gvsd.HomeLibraryExists.plist" ]; then
    WriteToLogs "Start sync from home for $CurrentUSER"
    
    rm -f "$MYHOMEDIR/Library/Preferences/com.apple.dock.plist" 
    
    local libfolders=(
      "Preferences"
      "PreferencePanes"
      "Saved Application State"
      "Safari"
      "SyncedPreferences"
    )
    
    for (( n=0; n < ${#libfolders[@]}; n++ )); do
      chown -R $CurrentUSER "/Users/$CurrentUSER/Library/${libfolders[n]}"
      chmod -R 777 "/Users/$CurrentUSER/Library/${libfolders[n]}"
      rsync -avz --exclude=".*" "$MYHOMEDIR/Library/${libfolders[n]}/" "/Users/$CurrentUSER/Library/${libfolders[n]}/"
      WriteToLogs "rsync code for ${libfolders[n]} from home is $?"
    done
    
    touch "$MYHOMEDIR/Library/Preferences/com.gvsd.HomeLibraryExists.plist" 
    touch "/Users/$CurrentUSER/Library/Preferences/com.gvsd.HomeLibraryExists.plist"        
  fi
  
  local end_time=$(date +%s)  # Capture end time in seconds
  local duration=$((end_time - start_time))  # Calculate duration
  WriteToLogs "### Finished ${FUNCNAME[0]} function in $duration seconds"
}

OnExit() {
  jamf policy -event synctohome
}

#################
# MAIN SEQUENCE #
#################

# Wrap the sequence in a progress UI.
display_progress() {
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

  WriteToLogs "Login script started."
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
  
  if [ "$ADUser" = "Student" ] || [ "$ADUser" = "Staff" ]; then
    CheckFolderPath "$ADUser"
  else
    WriteToLogs "Unknown ADUser value: $ADUser" 
  fi
    
  WriteToLogs "Home Folder is $MYHOMEDIR"
  
  # if [ "$ADUser" = "Student" ]; then
  # OVERRIDE to do these functions for Staff as well:
  if [ "$ADUser" = "Student" ] || [ "$ADUser" = "Staff" ]; then
    if [ ! -d "$MYHOMEDIR/Library/Preferences" ]; then
      CreateHomeLibraryFolders
    else
      WriteToLogs "Home Library exists already"
    fi
  fi
  
  RedirectIfADAccount
    
  # Pin redirected folders
  if [ -f "/Users/$CurrentUSER/Library/Application Support/com.gvsd.PinFolders.plist" ]; then
    WriteToLogs "Redirected folders already pinned"
  elif [ -f "/Users/$CurrentUSER/Library/Application Support/com.gvsd.RedirectedFolders.plist" ]; then
    WriteToLogs "Pinning folders to sidebar"
    PinRedirectedFolders
  fi
    
  # if [ "$ADUser" = "Student" ]; then
  # OVERRIDE to do these functions for Staff as well:
  if [ "$ADUser" = "Student" ] || [ "$ADUser" = "Staff" ]; then
    if [ ! -d "/Users/$CurrentUSER/Documents/Sync" ]; then 
      CreateDocumentLibraryFolders
    fi
    
    if [ ! -d "/Users/$CurrentUSER/Library/Application Support/Google/Chrome/Profile 1" ]; then 
      PreStageUnlinkedAppFolders
    fi
    
    LinkLibraryFolders
    SyncHomeLibraryToLocal
    LinkTwineFolders
  fi
  
  FixLibraryPerms
  CopyRoamingAppFiles
  
  WriteToLogs "Login script complete."
  echo -n "/bottom_message Done!" >&3
  
  # Tell the progress UI to close, and clean up.
  echo -n "/percent 100" >&3
  exec 3>&-
  rm -f "/tmp/${PIPE_NAME}"
  
  # Fully kill the Notifier UI.
  kill -TERM "$Notifier_Process"
}

# Do the main sequence, wrapped by the progress UI.
display_progress

if [ "$ADUser" = "Student" ]; then
  trap OnExit exit
fi

exit 0