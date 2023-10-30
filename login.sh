#!/bin/zsh

#####################################################
# Login script to handle various folder redirections. 
#####################################################

# Set initial variables
USER=`who | grep "console" | cut -d" " -f1`
CurrentUSER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /Loginwindow/ { print $3 }' )
MacName=$( scutil --get ComputerName)
uid=$(id -u "$CurrentUSER")

# funcstack will be used for simpler logging
setopt FUNCSTACK

# Set logfile location
SYNCLOG="/tmp/LibrarySync.log"

# Rotate the log
if [ -f "$SYNCLOG" ]; then 
  mv "$SYNCLOG" "/tmp/LibrarySynclog-`date`.log"
fi

touch "$SYNCLOG"
chmod 777 "$SYNCLOG"

# Not sure what this permission grant is for
chmod 777 /usr/local/ConsoleUserWarden/bin/ConsoleUserWarden-UserLoggedOut

###########
# Functions
###########

WriteToLogs() {
  local message="$1"
  local now=$(date "+%Y-%m-%d %T")
  echo "$now - $message" >> "$SYNCLOG"
  echo "$now - $message"
}

RunAsUser() {  
  if [ "$CurrentUSER" != "loginwindow" ]; then
    launchctl asuser "$uid" sudo -u "$CurrentUSER" "$@"
  else
    WriteToLogs "No user logged in."
    exit 1
  fi
}

CreateFolderAndSetPermissions() {
  local dir_path="$1"
  local owner="$2"
  
  if [ ! -d "$dir_path" ]; then
    mkdir -p "$dir_path"
    chown "$owner" "$dir_path"
    chmod -R 777 "$dir_path"
  fi
}

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

CheckStudentFolderPath() {
  if [ -d /Volumes/$CurrentUSER ]; then
    MYHOMEDIR=/Volumes/$CurrentUSER
  fi
  
  if [ -d /Volumes/StudentHome\$ ]; then 
    MYHOMEDIR=/Volumes/StudentHome\$/$CurrentUSER
  else
    MYHOMEDIR=/Volumes/Studenthome\$/$CurrentUSER
  fi
}

CheckStaffFolderPath() {
  if [ -d /Volumes/$CurrentUSER ]; then
    MYHOMEDIR=/Volumes/$CurrentUSER
  fi
  
  if [ -d /Volumes/StaffHome\$ ]; then 
    MYHOMEDIR=/Volumes/StaffHome\$/$CurrentUSER
  else
    MYHOMEDIR=/Volumes/Staffhome\$/$CurrentUSER
  fi
}

RedirectIfADAccount()  {
  WriteToLogs "Started $funcstack[1] function"
  
  # Redirect home folders to server.
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
    
    # Generate a plist to indicate this process is complete
    touch "/Users/$CurrentUSER/Library/Application Support/com.gvsd.RedirectedFolders.plist"
    chown $CurrentUSER "/Users/$CurrentUSER/Library/Application Support/com.gvsd.RedirectedFolders.plist"
    chmod 755 "/Users/$CurrentUSER/Library/Application Support/com.gvsd.RedirectedFolders.plist"
  fi
  
 WriteToLogs "Finished $funcstack[1] function"
}

PinRedirectedFolders()  {
  WriteToLogs "Started $funcstack[1] function"
  
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
  
  WriteToLogs "Finished $funcstack[1] function"
}

CreateHomeLibraryFolders()  {
  WriteToLogs "Started $funcstack[1] function"

  if [ -d "$MYHOMEDIR/Library/SyncedPreferences" ]; then
    WriteToLogs "Library available"
    
    # Generate plists to indicate this process is complete
    touch "$MYHOMEDIR/Library/Preferences/com.gvsd.HomeLibraryExists.plist" 
    touch "/Users/$CurrentUSER/Library/Preferences/com.gvsd.HomeLibraryExists.plist" 
  else
    chmod -R 777 "$MYHOMEDIR"
    
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
  
  WriteToLogs "Finished $funcstack[1] function" 
}

CreateDocumentLibraryFolders() {
  WriteToLogs "Started $funcstack[1] function"
  
  # Set of Documents folders to create
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

  WriteToLogs "Finished $funcstack[1] function"
}

PreStageUnlinkedAppFolders() {
  WriteToLogs "Started $funcstack[1] function"
  
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
  
  WriteToLogs "Finished $funcstack[1] function"
}

LinkLibraryFolders() {  
  WriteToLogs "Started $funcstack[1] function"
  
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
  
  WriteToLogs "Finished $funcstack[1] function"
}

LinkTwineFolders() { 
  WriteToLogs "Started $funcstack[1] function"
  
  mkdir -p "/Users/$CurrentUSER/Twine"
  chmod -R 777 "/Users/$CurrentUSER/Twine"
  
  if [ ! -L "/Users/$CurrentUSER/Documents/Twine" ]; then
    WriteToLogs "Twine is not linked, now linking..."
    rm -Rf "/Users/$CurrentUSER/Documents/Twine"
    ln -s "/Users/$CurrentUSER/Twine" "/Users/$CurrentUSER/Documents/"
  else
    WriteToLogs "Twine subfolder already linked"
  fi
  
  WriteToLogs "Finished $funcstack[1] function"
}

FixLibraryPerms() {
  WriteToLogs "Started $funcstack[1] function"
  
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
  
    adjust_permissions "/Applications/Minecraft.app/Contents/MacOS/launcher" "777" "root" "wheel"
    adjust_permissions "/Users/$CurrentUSER/Library/Application Support/minecraft" "777"
    adjust_permissions "/Users/$CurrentUSER/Documents/Application Support/minecraft" "777"
    adjust_permissions "/Users/$CurrentUSER/Documents/Application Support/minecraft/saves" "777" "$CurrentUSER"
    adjust_permissions "/Users/Shared/minecraft/assets" "777" "root" "wheel"
    adjust_permissions "/Users/$CurrentUSER/Music/Audio Music Apps" "777"
    adjust_permissions "/Users/$CurrentUSER/Music/GarageBand" "777"
    adjust_permissions "/Users/$CurrentUSER/Library/Application Support/Google" "777"
  
  WriteToLogs "Finished $funcstack[1] function"
}

CopyRoamingAppFiles() {
  WriteToLogs "Started $funcstack[1] function"
  
  local srcBase="/Users/$CurrentUSER/Documents/Application Support/minecraft"
  local destBase="/Users/$CurrentUSER/Library/Application Support/minecraft"
  
  # Sync the Ninecraft saves directory
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
  
  WriteToLogs "Finished $funcstack[1] function"
}

OnExit() {
  jamf policy -event synctohome
}

SyncHomeLibraryToLocal() {
  WriteToLogs "Started $funcstack[1] function"
  
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
      rsync -avz --exclude=".*" "$MYHOMEDIR/Library/${libfolders[n]}/" "/Users/$USER/Library/${libfolders[n]}/"
      WriteToLogs "rsync code for ${libfolders[n]} from home is $?"
    done
    
    touch "$MYHOMEDIR/Library/Preferences/com.gvsd.HomeLibraryExists.plist" 
    touch "/Users/$CurrentUSER/Library/Preferences/com.gvsd.HomeLibraryExists.plist"        
  fi
  
  WriteToLogs "Finished $funcstack[1] function"
}

###############
# Main Sequence
###############

WriteToLogs "Current User: $CurrentUSER"

touch "/Users/$CurrentUSER/Library/Application Support/com.gvsd.LogonScriptRun.plist"
chown $CurrentUser "/Users/$CurrentUSER/Library/Preferences/com.apple.dock.plist"

CheckIfADAccount

if [ $AD = "1" ]; then
  CheckADUserType
fi

RunAsUser osascript -e 'display alert "Please wait while we set up your profile."'

if [ "$ADUser" = "Student" ]; then  
  CheckStudentFolderPath
else
  if [ "$ADUser" = "Staff" ]; then
    CheckStaffFolderPath
  fi
fi
  
WriteToLogs "Home Folder is $MYHOMEDIR"

if [ "$ADUser" = "Student" ]; then 
  if [ ! -d "$MYHOMEDIR/Library/Preferences" ]; then
    CreateHomeLibraryFolders
  else
    WriteToLogs "Home Library exists already"
  fi
fi

RedirectIfADAccount
  
# Pin redirected folders
if [ -f "/Users/$CurrentUSER/Library/Application Support/com.gvsd.PinFolders.plist" ] ; then
  WriteToLogs "Redirected folders already pinned"
else
  if [ -f "/Users/$CurrentUSER/Library/Application Support/com.gvsd.RedirectedFolders.plist" ] ; then
    WriteToLogs "Pinning folders to sidebar"
    PinRedirectedFolders
  fi
fi
  
if [ "$ADUser" = "Student" ]; then 
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
  
sleep 5

FixLibraryPerms
CopyRoamingAppFiles
RunAsUser osascript -e 'display alert "You are good to go. Thank you for waiting."'

if [ "$ADUser" = "Student" ]; then
  trap OnExit exit
fi

exit 0