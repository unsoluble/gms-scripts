#!/bin/zsh

#####################################################
# Login script to handle various folder redirections. 
#####################################################

# Set initial variables
USER=`who | grep "console" | cut -d" " -f1`
CurrentUSER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /Loginwindow/ { print $3 }' )
MacName=$( scutil --get ComputerName)
uid=$(id -u "$CurrentUSER") 

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
  
  if [ "$accountCheck" != "" ] && [[ $CurrentUSER = [0-9]* ]]; then
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
  if [ ! -f /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.RedirectedFolders.plist ]; then
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
            mkdir "$MYHOMEDIR/$i"
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
    touch /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.RedirectedFolders.plist
    chown $CurrentUSER /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.RedirectedFolders.plist
    chmod 755 /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.RedirectedFolders.plist
  fi
  
 WriteToLogs "Finsihed $funcstack[1] function"
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
  
  uid=$(id -u "$CurrentUSER")
  
  # Remove default pinned Sidebar folders
  remove_mysides $uid "Desktop" "Downloads" "Documents" "Pictures" "Music" "Library"
  
  # Pin new Sidebar folders
  add_mysides $uid "Desktop" "Downloads" "Documents" "Pictures" "Music" "Library"
  
  # Generate a plist to indicate this process is complete
  touch /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.PinFolders.plist
  chown $CurrentUSER /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.PinFolders.plist
  chmod 755 $CurrentUSER /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.PinFolders.plist
  
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
    chmod -R 777 $MYHOMEDIR
    
    # First create the root Library folder
    if [ ! -d "$MYHOMEDIR/Library" ]; then
      mkdir "$MYHOMEDIR/Library"
      chown $CurrentUSER "$MYHOMEDIR/Library"
    fi
    
    # Function to create the subfolder if needed, then adjust its ownership and perms
    create_and_set_permissions() {
      local dir_path="$1"
      local owner="$2"
      
      if [ ! -d "$dir_path" ]; then
        mkdir "$dir_path"
        chown "$owner" "$dir_path"
        chmod -R 777 "$dir_path"
      fi
    }
    
    # Set of Library folders to create
    local directories=(
      "Preferences"
      "PreferencePanes"
      "Safari"
      "Saved Application State"
      "SyncedPreferences"
    )
    
    for dir in "${directories[@]}"; do
      create_and_set_permissions "$MYHOMEDIR/Library/$dir" "$CurrentUSER"
    done
    
    # Generate plists to indicate this process is complete
    touch "$MYHOMEDIR/Library/Preferences/com.gvsd.HomeLibraryExists.plist" 
    touch "/Users/$CurrentUSER/Library/Preferences/com.gvsd.HomeLibraryExists.plist" 
  fi 
  
  WriteToLogs "Started $funcstack[1] function" 
}

CreateDocumentLibraryFolders() {
  WriteToLogs "Started $funcstack[1] function"
  
  # Create Application Support Folders in Documents
  if [ ! -d /Users/$CurrentUSER/Documents/Application\ Support ]; then
    mkdir /Users/$CurrentUSER/Documents/Application\ Support
  fi
  
  if [ ! -d "/Users/$CurrentUSER/Documents/Application Support/minecraft" ]; then
    mkdir /Users/$CurrentUSER/Documents/Application\ Support/minecraft
  fi
  
  if [ ! -d "/Users/$CurrentUSER/Documents/Application Support/minecraft/saves" ]; then
    mkdir /Users/$CurrentUSER/Documents/Application\ Support/minecraft/saves
    chown -R $CurrentUSER /Users/$CurrentUSER/Documents/Application\ Support/minecraft
    chmod -R 777 /Users/$CurrentUSER/Documents/Application\ Support/minecraft/saves
  fi
  
  if [ ! -d /Users/$CurrentUSER/Documents/GarageBand ]; then 
    mkdir /Users/$CurrentUSER/Documents/GarageBand
    chown -R $CurrentUSER /Users/$CurrentUSER/Documents/GarageBand
  fi
  
  if [ ! -d /Users/$CurrentUSER/Documents/Sync ]; then
    mkdir /Users/$CurrentUSER/Documents/Sync
    chown -R $CurrentUSER /Users/$CurrentUSER/Documents/Sync
    chmod -R 777 /Users/$CurrentUSER/Documents/Sync
  fi    
  
  if [ ! -d /Users/$CurrentUSER/Documents/Sync/Twine ]; then
    mkdir /Users/$CurrentUSER/Documents/Sync/Twine
    chown -R $CurrentUSER /Users/$CurrentUSER/Documents/Sync/Twine
    chmod -R 777 /Users/$CurrentUSER/Documents/Sync/Twine
  fi    
  
  if [ ! -d /Users/$CurrentUSER/Documents/Sync/Twine/Stories ]; then
    mkdir /Users/$CurrentUSER/Documents/Sync/Twine/Stories
    chown -R $CurrentUSER /Users/$CurrentUSER/Documents/Sync/Twine/Stories
    chmod -R 777 /Users/$CurrentUSER/Documents/Sync/Twine/Stories
  fi    
  
  if [ ! -d /Users/$CurrentUSER/Documents/Sync/Twine/Backups ]; then
    mkdir /Users/$CurrentUSER/Documents/Sync/Twine/Backups
    chown -R $CurrentUSER /Users/$CurrentUSER/Documents/Sync/Twine/Backups
    chmod -R 777 /Users/$CurrentUSER/Documents/Sync/Twine/Backups
  fi    
  
  if [ ! -d /Users/$CurrentUSER/Twine ]; then
    mkdir /Users/$CurrentUSER/Twine
    chown -R $CurrentUSER /Users/$CurrentUSER/Twine
    chmod -R 777 /Users/$CurrentUSER/Twine
  fi    
  
  # The following is for use with the Chrome launcher that defines a user profile folder
  if [ ! -d /Users/$CurrentUSER/Documents/Application\ Support/Google/Chrome/Profile\ 1 ]; then
    mkdir /Users/$CurrentUSER/Documents/Application\ Support/Google/Chrome/Profile\ 1
    chown -R $CurrentUSER /Users/$CurrentUSER/Documents/Application\ Support
  fi 
  
 WriteToLogs "Finished $funcstack[1] function"
}

PreStageUnlinkedAppFolders() {
  WriteToLogs "Started $funcstack[1] function"
  
  # Create Application Support Folders in Library and in Music
  if [ ! -d /Users/$CurrentUSER/Library/Application\ Support ]; then
    mkdir /Users/$CurrentUSER/Library/Application\ Support
  fi
  
  if [ ! -d /Users/$CurrentUSER/Library/Application\ Support/minecraft ]; then
    mkdir /Users/$CurrentUSER/Library/Application\ Support/minecraft
  fi
  
  if [ ! -d /Users/$CurrentUSER/Library/Application\ Support/minecraft/saves ]; then
    mkdir /Users/$CurrentUSER/Library/Application\ Support/minecraft/saves
    #chown -R $CurrentUSER /Users/$CurrentUSER/Documents/Application\ Support/minecraft/saves
    chmod -R 777 /Users/$CurrentUSER/Documents/Application\ Support/minecraft/saves
    chmod -R 777 /Users/$CurrentUSER/Documents/Application\ Support/minecraft/saves
  fi
  
  if [ ! -d /Users/$CurrentUSER/Music/Audio\ Music\ Apps ]; then 
    mkdir /Users/$CurrentUSER/Music/Audio\ Music\ Apps
    chown -R $CurrentUSER /Users/$CurrentUSER/Documents/Audio\ Music\ Apps
    chmod -R 777 /Users/$CurrentUSER/Documents/Audio\ Music\ Apps
  fi
  
  if [ ! -d /Users/$CurrentUSER/Music/GarageBand ]; then 
    mkdir /Users/$CurrentUSER/Music/GarageBand
    chown -R $CurrentUSER /Users/$CurrentUSER/Music/GarageBand
    chmod -R 777 /Users/$CurrentUSER/Music/GarageBand
  fi
  
  if [ ! -d /Users/$CurrentUSER/Library/Application\ Support/Google ]; then
    mkdir /Users/$CurrentUSER/Library/Application\ Support/Google
  fi
  
  if [ ! -d /Users/$CurrentUSER/Library/Application\ Support/Google/Chrome ]; then
    mkdir /Users/$CurrentUSER/Library/Application\ Support/Google/Chrome
  fi
  
  if [ ! -d /Users/$CurrentUSER/Library/Application\ Support/Google/Chrome/Profile\ 1 ]; then
    mkdir /Users/$CurrentUSER/Library/Application\ Support/Google/Chrome/Profile\ 1
    chown -R $CurrentUSER /Users/$CurrentUSER/Library/Application\ Support/Google
    chmod -R 777 /Users/$CurrentUSER/Library/Application\ Support/Google
  fi
  
  WriteToLogs "Finished $funcstack[1] function"
}

LinkLibraryFolders() {  
  WriteToLogs "Started $funcstack[1] function"
  
  # Symlink minecraft folders to machine local shared
  if [ ! -d /Users/Shared/minecraft ]; then
    mkdir /Users /Shared/minecraft
  fi
  
  if [ ! -d /Users/$CurrentUSER/Library/Application\ Support/minecraft ]; then
    mkdir /Users/$CurrentUSER/Library/Application\ Support/minecraft
  fi    
  
  mineFolders=(
    "assets"
    "versions"
  )
  
  for (( m=0; m < ${#mineFolders[@]}; m++ )); do
    if [ -d "/Users/Shared/minecraft/${mineFolders[m]}" ]; then
      echo "Shared minecraft ${mineFolders[m]} folder available"
      chown -R root:wheel /Users/Shared/minecraft/${mineFolders[m]}
      chmod -R 777 /Users/Shared/minecraft/${mineFolders[m]}
    else
      echo "Shared minecraft ${mineFolders[m]} not available, creating...."
      mkdir /Users/Shared/minecraft/${mineFolders[m]}
      chown -R root:wheel /Users/Shared/minecraft/${mineFolders[m]}
      chmod -R 777 /Users/Shared/minecraft/${mineFolders[m]}
    fi
    
    if [ ! -L "/Users/$CurrentUSER/Library/Application Support/minecraft/${mineFolders[m]}" ]; then
      echo "Application Support subfolder minecraft ${mineFolders[m]} is not linked, now linking"
      rm -R "/Users/$CurrentUSER/Library/Application Support/minecraft/${mineFolders[m]}"
      ln -s "/Users/Shared/minecraft/${mineFolders[m]}" "/Users/$CurrentUSER/Library/Application Support/minecraft/"
    else
      echo "minecraft ${mineFolders[m]} subfolder already linked, going away now"
    fi
  done
  
  # Symlink Application Sub Folders
  echo "creating Application Support subfolder symlinks"
  
  appSubfolders=(
    "Dock"
    "iMovie"
  )
  
  echo "starting symlinks"
  
  for x in "${appSubfolders[@]}"; do
    if [ -d /Users/$CurrentUSER/Documents/Application\ Support/$x ]; then
      echo "$x available"
    else
      echo "$x not available, creating...."
      mkdir /Users/$CurrentUSER/Documents/Application\ Support/$x
      chmod -R 777 /Users/$CurrentUSER/Documents/Application\ Support/$x
    fi
    
    # ap=${appSubfolders[x]//[[:blank:]]} 
    # echo "$ap"
    # aplistlink="com.gvsd.${ap}.Linked.plist"
    # echo "$aplistlink"
    
    echo "testing symlinks"
    iold="${x}_OLD"    
    
    if [ ! -L /Users/$CurrentUSER/Library/Application\ Support/$x ]; then
      echo "Application Support subfolder $x is not linked, now linking"
      rm -Rf /Users/$CurrentUSER/Library/Application\ Support/$x
      ln -s /Users/$CurrentUSER/Documents/Application\ Support/$x /Users/$CurrentUSER/Library/Application\ Support/
    else
      echo "$x subfolder already linked, going away now"
    fi
  done 
  
  WriteToLogs "Finished $funcstack[1] function"
}

LinkTwineFolders() { 
  WriteToLogs "Started $funcstack[1] function"
  
  if [ -d /Users/$CurrentUSER/Twine ]; then
    echo "Twine folder available"
  else
    echo "Twine is not available, creating...."
    mkdir /Users/$CurrentUSER/Twine
    chmod -R 777 /Users/$CurrentUSER/Twine
  fi
  
  if [ ! -L /Users/$CurrentUSER/Documents/Twine ]; then
    echo "Twine is not linked, now linking"
    rm -Rf /Users/$CurrentUSER/Documents/Twine
    ln -s /Users/$CurrentUSER/Twine /Users/$CurrentUSER/Documents/
  else
    echo "Twine subfolder already linked, going away now"
  fi
  
  WriteToLogs "Finished $funcstack[1] function"
}

FixLibraryPerms() {
  WriteToLogs "Started $funcstack[1] function"
  
  if [ ! "$(stat -f '%A' /Applications/Minecraft.app/Contents/MacOS/launcher)" = 777 ]; then
    chown -R root:wheel /Applications/Minecraft.app 
    chmod -R 777 /Applications/Minecraft.app/Contents/MacOS/launcher
    now=$( date +%T )
    echo "$now - Set permissions for Minecraft" >> "$SYNCLOG"
  fi
  
  if [ ! "$(stat -f '%A' /Users/$CurrentUSER/Library/Application\ Support/minecraft)" = 777 ]; then
    chmod -R 777 /Users/$CurrentUSER/Library/Application\ Support/minecraft
    chmod -R 777 /Users/$CurrentUSER/Documents/Application\ Support/minecraft
    chown -R $CurrentUSER  /Users/$CurrentUSER/Documents/Application\ Support/minecraft/saves           
    chown -R root:wheel /Users/Shared/minecraft/assets
    chmod -R 777 /Users/Shared/minecraft/assets
  fi
  
  if [ ! "$(stat -f '%a' chmod -R 777 /Users/$CurrentUSER/Music/Audio\ Music\ Apps)" == "777" ]; then
    chmod -R 777 /Users/$CurrentUSER/Music/Audio\ Music\ Apps
  fi
  
  if [ ! "$(stat -f '%A' /Users/$CurrentUSER/Music/GarageBand)" = 777 ]; then
    chmod -R 777 /Users/$CurrentUSER/Music/GarageBand
    echo "$now - Set permissions for Music Folder" >> "$SYNCLOG"
  fi
  
  if [ ! "$(stat -f '%A' /Users/$CurrentUSER/Library/Application\ Support/Google)" = "777" ]; then
    chmod -R 777 /Users/$CurrentUSER/Library/Application\ Support/Google
  fi 
  
  WriteToLogs "Finished $funcstack[1] function"
}

CopyRoamingAppFiles() {
  WriteToLogs "Started $funcstack[1] function"
  
  ### Minecraft Files
  if [ ! -d /Users/$CurrentUSER/Library/Application\ Support/minecraft/launcher ]; then
    rm -R /Users/$CurrentUSER/Library/Application\ Support/minecraft/launcher
  fi
  
  # if [ -f /Users/Shared/minecraft/launcher/launcher.bundle ]; then
  #   rsync -rua /Users/Shared/minecraft/launcher/ /Users/$CurrentUSER/Library/Application\ Support/minecraft/launcher/ 
  # fi
  
  rsync -rua /Users/$CurrentUSER/Documents/Application\ Support/minecraft/saves/ /Users/$CurrentUSER/Library/Application\ Support/minecraft/saves/ 
  cp -Rf /Users/$CurrentUSER/Documents/Application\ Support/minecraft/launcher_accounts.json  /Users/$CurrentUSER/Library/Application\ Support/minecraft 
  cp -Rf /Users/$CurrentUSER/Documents/Application\ Support/minecraft/launcher_msa_credentials.bin  /Users/$CurrentUSER/Library/Application\ Support/minecraft  
  cp -Rf /Users/$CurrentUSER/Documents/Application\ Support/minecraft/options.txt  /Users/$CurrentUSER/Library/Application\ Support/minecraft 
  chmod -R 777 /Users/Shared/minecraft
  
  now=$( date +%T )
  echo "$now - Copied Minecraft" >> "$SYNCLOG"
  echo "$now - Copied Minecraft"
  
  ### Garageband Files
  rsync -rua /Users/$CurrentUSER/Documents/GarageBand/ /Users/$CurrentUSER/Music/GarageBand/
  echo "$now - Copied GarageBand Folder" >> "$SYNCLOG"
  echo "$now - Copied GarageBand Folder"
  
  ### Twine Files
  rsync -rua /Users/$CurrentUSER/Documents/Sync/Twine/ /Users/$CurrentUSER/Twine/
  echo "$now - Copied Twine Folders" >> "$SYNCLOG"
  echo "$now - Copied Twine Folders"
  
  WriteToLogs "Finished $funcstack[1] function"
}

OnExit() {
  jamf policy -event synctohome
}

SyncHomeLibraryToLocal() {
  WriteToLogs "Started $funcstack[1] function"
  
  if [ -f "$MYHOMEDIR/Library/Preferences/com.gvsd.HomeLibraryExists.plist" ]; then
    echo "`date` - Start sync from home for $CurrentUSER" >> "$SYNCLOG"
    echo "`date` - Start sync from home for $CurrentUSER"
    # RunAsUser osascript -e 'display alert "Sync From Home" message "Your Library is downloading."' &
    now=$( date +%T )
    rm -f "$MYHOMEDIR/Library/Preferences/com.apple.dock.plist" 
    
    libfolders=(
      "Preferences"
      "PreferencePanes"
      "Saved Application State"
      "Safari"
      "SyncedPreferences"
    )
    
    for (( n=0; n < ${#libfolders[@]}; n++ )); do
      now=$( date +%T )
      chown -R $CurrentUSER "/Users/$CurrentUSER/Library/${libfolders[n]}"
      chmod -R 777 "/Users/$CurrentUSER/Library/${libfolders[n]}"
      # chmod -R 777 "$MYHOMEDIR/Library/${libfolders[n]}"
      rsync -rua --exclude=".*" "$MYHOMEDIR/Library/${libfolders[n]}/" "/Users/$USER/Library/${libfolders[n]}/"
      echo "$now - rsync code for ${libfolders[n]} from home is $?" >> "$SYNCLOG"
      echo "$now - rsync code for ${libfolders[n]} from home is $?"
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

touch /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.LogonScriptRun.plist
chown $CurrentUser /Users/$CurrentUSER/Library/Preferences/com.apple.dock.plist

CheckIfADAccount

if [ $AD = "1" ]; then
  CheckADUserType
fi

if [ "$ADUser" = "Student" ]; then
  RunAsUser osascript -e 'display alert "Please wait while we set up your profile."'
  
  CheckStudentFolderPath
  
  echo "Home Folder is $MYHOMEDIR" >> "$SYNCLOG"
  echo "Home Folder is $MYHOMEDIR"
  
  if [ ! -d "$MYHOMEDIR/Library/Preferences" ]; then
    CreateHomeLibraryFolders
    echo "Creating Library template" >> "$SYNCLOG"
    echo "Creating Library template"
  else
    echo "Home Library exists already" >> "$SYNCLOG"
    echo "Home Library exists already"
  fi
  
  RedirectIfADAccount
  
  # Pin redirected folders
  if [ -f /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.PinFolders.plist ] ; then
    Echo "Redirected folders already pinned"
  else
    if [ -f /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.RedirectedFolders.plist ] ; then
      echo "Pinning folders to sidebar" >> "$SYNCLOG"
      echo "Pinning folders to sidebar"
      PinRedirectedFolders
    fi
  fi
  
  if [ ! -d /Users/$CurrentUSER/Documents/Sync ]; then 
    CreateDocumentLibraryFolders
  fi
  
  if [ ! -d /Users/$CurrentUSER/Library/Application\ Support/Google/Chrome/Profile\ 1  ]; then 
    PreStageUnlinkedAppFolders
  fi
  
  LinkLibraryFolders
  
  # Sync User's Home Library with local library.
  SyncHomeLibraryToLocal
  
  LinkTwineFolders
  
  sleep 5
  
  FixLibraryPerms &
  
  CopyRoamingAppFiles
  
  RunAsUser osascript -e 'display alert "You are good to go. Thank you for waiting"'
fi

if [ "$ADUser" = "Staff" ]; then
  RunAsUser osascript -e 'display alert "Please wait while we set up your profile."'
  
  CheckStaffFolderPath
  echo "Home Folder is $MYHOMEDIR" >> "$SYNCLOG"
  echo "Home Folder is $MYHOMEDIR"
  
  RedirectIfADAccount
  
  # Pin redirected folders
  if [ -f /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.PinFolders.plist ] ; then
    Echo "Redirected folders already pinned"
  else
    if [ -f /Users/$CurrentUSER/Library/Application\ Support/com.gvsd.RedirectedFolders.plist ] ; then
      echo "Pinning folders to sidebar" >> "$SYNCLOG"
      echo "Pinning folders to sidebar"
      PinRedirectedFolders
    fi
  fi
  
  sleep 5
  RunAsUser osascript -e 'display alert "You are good to go. Thank you for waiting"'
fi

# Start the library sync back to home
echo "`date` - Start sync back to home for $CurrentUSER" >> "$SYNCLOG"
echo "`date` - Start sync back to home for $CurrentUSER"

#jamf policy -event synctohome &&

if [ "$ADUser" = "Student" ]; then
  trap OnExit exit
fi

exit 0