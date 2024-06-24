#!/bin/zsh

############################################################
# Save & Log Out script, to be called by an Automator app. #
############################################################

SCRIPT_VERSION="2024-06-24-1358"

# Set up sync sources and destinations.
declare -A RSYNC_PAIRS

RSYNC_PAIRS=(
  ["${HOME}/Library/Application Support/minecraft/saves/"]="${HOME}/Documents/Application Support/minecraft/saves/"
  ["${HOME}/Library/Application Support/minecraft/curseforge/"]="${HOME}/Documents/Application Support/minecraft/curseforge/"
  ["${HOME}/Library/Application Support/minecraft/launcher_accounts.json"]="${HOME}/Documents/Application Support/minecraft/"
  ["${HOME}/Library/Application Support/minecraft/launcher_msa_credentials.bin"]="${HOME}/Documents/Application Support/minecraft/"
  ["${HOME}/Library/Application Support/minecraft/options.txt"]="${HOME}/Documents/Application Support/minecraft/"
  ["${HOME}/Music/GarageBand/"]="${HOME}/Documents/GarageBand/"
  ["${HOME}/Twine/"]="${HOME}/Documents/Sync/Twine/"
)

# Set up a unique logfile for the current user.
CurrentUSER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /Loginwindow/ { print $3 }' )
RSYNC_LOG="/tmp/${CurrentUSER}_logout_log.txt"

# Notifier UI paths.
APP_PATH="/Applications/IBM Notifier.app/Contents/MacOS/IBM Notifier"
ICON_PATH="/Library/Scripts/GVSD/logout_icon.png"

# Variables for the confirmation dialog.
CONF_BAR_TITLE="Save & Log Out"
CONF_TITLE="Are you sure you want to log out now?"
CONF_TIMER="You'll be logged out automatically in %@ seconds."
CONF_SECONDS=30
CONF_MAIN_BUTTON="Save & Log Out"
CONF_SECONDARY_BUTTON="Cancel"

# Variables for the progress dialog.
PROG_BAR_TITLE="Save & Log Out"
PROG_TITLE="Syncing your files! You'll be logged out when this finishes."
PROG_ACCESSORY_TYPE="progressbar"
PROG_ACCESSORY_PAYLOAD="/percent indeterminate \
                        /user_interruption_allowed true \
                        /exit_on_completion true"
PROG_TIMEOUT_SECONDS=300
PROG_MAIN_BUTTON="Cancel"

# Set up a temporary pipe for the sync progress window.
PIPE_NAME="notif"
rm -f /tmp/${PIPE_NAME}
mkfifo /tmp/${PIPE_NAME}
exec 3<> /tmp/${PIPE_NAME}

#############
# Functions #
#############

# Pop a dialog confirming the intent to log out.
confirm_logout() {
  ${APP_PATH} \
    -type "popup" \
    -bar_title ${CONF_BAR_TITLE} \
    -title ${CONF_TITLE} \
    -icon_path ${ICON_PATH} \
    -accessory_view_type timer \
    -accessory_view_payload ${CONF_TIMER} \
    -timeout ${CONF_SECONDS} \
    -main_button_label ${CONF_MAIN_BUTTON} \
    -secondary_button_label ${CONF_SECONDARY_BUTTON} \
    -always_on_top
  echo "$?"
}

# Use rsync to sync the passed source to its destination, while updating the dialog UI.
perform_rsync() {
  SOURCE_DIR="$1"
  DEST_DIR="$2"
  
  # Pre-make directory structures if they're missing.
  mkdir -p "$(dirname "${DEST_DIR}")"
  mkdir -p "$(dirname "${RSYNC_LOG}")"
  
  echo "$(date +"%Y-%m-%d %H:%M:%S") -- Sync start for ${SOURCE_DIR}\n" >> "${RSYNC_LOG}"
  
  # Perform the rsync operation.
  rsync -avz "$SOURCE_DIR" "$DEST_DIR" >> "${RSYNC_LOG}" 2>&1 &
  local rsync_pid=$!
  
  # Update the progress UI with the name of the last-sync'd file.
  while ps -p $rsync_pid > /dev/null; do
    if [[ $(pgrep -q "IBM Notifier"; echo $?) -ne 0 ]]; then
      # Sync cancelled.
      local CANCEL=1
      echo "Cancelling"
      kill -TERM "$rsync_pid"
      break
    fi
    local latest_output=$(basename "$(tail -n 1 "${RSYNC_LOG}")")
    echo -n "/bottom_message Currently syncing file: ${latest_output}" >&3
    sleep 0.2
  done
  
  wait $rsync_pid
  echo "\n$(date +"%Y-%m-%d %H:%M:%S") -- Sync complete!\n" >> "${RSYNC_LOG}"
}

# Pop a dialog displaying an in-progress status bar for the sync, with a cancel button.
display_progress() {
  ${APP_PATH} \
    -type "popup" \
    -title ${PROG_TITLE} \
    -bar_title ${PROG_BAR_TITLE} \
    -icon_path ${ICON_PATH} \
    -accessory_view_type ${PROG_ACCESSORY_TYPE} \
    -accessory_view_payload ${PROG_ACCESSORY_PAYLOAD} \
    -main_button_label ${PROG_MAIN_BUTTON} \
    -timeout ${PROG_TIMEOUT_SECONDS} \
    -always_on_top < /tmp/${PIPE_NAME} &
  
  # Run a sync for each of the listed source/destination pairs.
  for source in "${(@k)RSYNC_PAIRS}"; do
    local destination="${RSYNC_PAIRS[$source]}"
    perform_rsync "$source" "$destination"
  done
  
  # Tell the progress UI to close, and clean up.
  echo -n "end" >&3
  exec 3>&-
  rm -f /tmp/${PIPE_NAME}
}

#################
# Main sequence #
#################

# Check for intentional logout.
local continue=$(confirm_logout)

# Continue with the sync or cancel.
if [ "$continue" -eq 0 ] || [ "$continue" -eq 4 ]; then
  rm -f ${RSYNC_LOG}
  display_progress
  
  # Clear out this plist file if it still exists.
  if [ -f "${HOME}/Library/Application Support/com.gvsd.LogonScriptRun.plist" ]; then
    rm -f "${HOME}/Library/Application Support/com.gvsd.LogonScriptRun.plist" 
  fi
  
  # Log out the user.
  osascript -e 'tell application "loginwindow" to «event aevtrlgo»'
else
  echo "Logout cancelled."
  exit 1
fi