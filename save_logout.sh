#!/bin/zsh

############################################################
# Save & Log Out script, to be called by an Automator app. #
############################################################

SCRIPT_VERSION="2025-11-24-1304"

# Determine ConsoleUser (the logged-in user) and that user's home directory.
CurrentUSER=$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /Loginwindow/ { print $3 }' )
# Prefer dscl to get exact NFSHomeDirectory; fall back to ~user expansion.
USER_HOME=$(dscl . -read /Users/"${CurrentUSER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
if [ -z "${USER_HOME}" ]; then
  USER_HOME=$(eval echo "~${CurrentUSER}")
fi

# Set up sync sources and destinations using the real user's home dir.
typeset -A RSYNC_PAIRS
RSYNC_PAIRS=(
  ["${USER_HOME}/Library/Application Support/minecraft/saves/"]="${USER_HOME}/Documents/Application Support/minecraft/saves/"
  ["${USER_HOME}/Library/Application Support/minecraft/curseforge/"]="${USER_HOME}/Documents/Application Support/minecraft/curseforge/"
  ["${USER_HOME}/Library/Application Support/minecraft/launcher_accounts.json"]="${USER_HOME}/Documents/Application Support/minecraft/"
  ["${USER_HOME}/Library/Application Support/minecraft/launcher_msa_credentials.bin"]="${USER_HOME}/Documents/Application Support/minecraft/"
  ["${USER_HOME}/Library/Application Support/minecraft/options.txt"]="${USER_HOME}/Documents/Application Support/minecraft/"
  ["${USER_HOME}/Music/GarageBand/"]="${USER_HOME}/Documents/GarageBand/"
  ["${USER_HOME}/Twine/"]="${USER_HOME}/Documents/Sync/Twine/"
)

# Set up a unique logfile for the current user.
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
PIPE_NAME="notif_${$}"
PIPE_PATH="/tmp/${PIPE_NAME}"
rm -f "${PIPE_PATH}"
mkfifo "${PIPE_PATH}"
exec 3<> "${PIPE_PATH}"

# Ensure fifo and fd are cleaned up on exit.
trap 'rm -f "${PIPE_PATH}"; exec 3>&- 2>/dev/null || true' EXIT

#############
# Functions #
#############

# Pop a dialog confirming the intent to log out.
confirm_logout() {
  "${APP_PATH}" \
    -type "popup" \
    -bar_title "${CONF_BAR_TITLE}" \
    -title "${CONF_TITLE}" \
    -icon_path "${ICON_PATH}" \
    -accessory_view_type timer \
    -accessory_view_payload "${CONF_TIMER}" \
    -timeout "${CONF_SECONDS}" \
    -main_button_label "${CONF_MAIN_BUTTON}" \
    -secondary_button_label "${CONF_SECONDARY_BUTTON}" \
    -always_on_top
  echo "$?"
}

# Use rsync to sync the passed source to its destination, while updating the dialog UI.
perform_rsync() {
  local SOURCE_DIR="$1"
  local DEST_DIR="$2"

  # Ensure destination exists (create the destination directory, not only its parent).
  mkdir -p "${DEST_DIR}"
  mkdir -p "$(dirname "${RSYNC_LOG}")"

  echo "Running Save & Log Out script version ${SCRIPT_VERSION}" >> "${RSYNC_LOG}"
  echo "$(date +"%Y-%m-%d %H:%M:%S") -- Sync start for ${SOURCE_DIR}" >> "${RSYNC_LOG}"

  # Start rsync in the background, capture its PID.
  rsync -avz --delete "${SOURCE_DIR}" "${DEST_DIR}" >> "${RSYNC_LOG}" 2>&1 &
  local rsync_pid=$!

  # Start a tail that watches the logfile and pushes updates to the notifier pipe.
  {
    tail -n0 -F "${RSYNC_LOG}" 2>/dev/null | while IFS= read -r line; do
      # Attempt to extract a human-friendly filename from the last rsync line.
      latest_output=$(basename "${line}" 2>/dev/null)
      # Send a short, stable message to the notifier (avoid spamming with long file names).
      echo -n "/bottom_message Currently syncing files, please wait." >&3
    done
  } &
  local tail_pid=$!

  # Monitor rsync and the notifier. If the notifier disappears, cancel the rsync.
  while kill -0 ${rsync_pid} 2>/dev/null; do
    # Use pgrep -f to match full command line, and test its exit status.
    if ! pgrep -f "IBM Notifier" >/dev/null 2>&1; then
      echo "$(date +"%Y-%m-%d %H:%M:%S") -- Notifier closed; cancelling rsync ${rsync_pid}" >> "${RSYNC_LOG}"
      kill -TERM "${rsync_pid}" 2>/dev/null || true
      break
    fi
    sleep 0.2
  done

  wait ${rsync_pid} 2>/dev/null || true

  # Clean up the tail process.
  kill ${tail_pid} 2>/dev/null || true

  echo "$(date +"%Y-%m-%d %H:%M:%S") -- Sync complete for ${SOURCE_DIR}" >> "${RSYNC_LOG}"
}

# Pop a dialog displaying an in-progress status bar for the sync, with a cancel button.
display_progress() {
  # Launch the notifier and feed it from our fifo. Keep it backgrounded so we can do rsync work.
  "${APP_PATH}" \
    -type "popup" \
    -title "${PROG_TITLE}" \
    -bar_title "${PROG_BAR_TITLE}" \
    -icon_path "${ICON_PATH}" \
    -accessory_view_type "${PROG_ACCESSORY_TYPE}" \
    -accessory_view_payload "${PROG_ACCESSORY_PAYLOAD}" \
    -main_button_label "${PROG_MAIN_BUTTON}" \
    -timeout "${PROG_TIMEOUT_SECONDS}" \
    -always_on_top < "${PIPE_PATH}" &

  # Give the notifier a short moment to start so pgrep sees it.
  sleep 0.25

  # Run a sync for each of the listed source/destination pairs.
  for source in "${(@k)RSYNC_PAIRS}"; do
    destination="${RSYNC_PAIRS[$source]}"
    perform_rsync "${source}" "${destination}"
  done

  # Tell the progress UI to close, and clean up.
  echo -n "end" >&3
  exec 3>&-
  rm -f "${PIPE_PATH}"
  # Remove the trap cleanup since we've already cleaned up here.
  trap - EXIT
}

#################
# Main sequence #
#################

# Check for intentional logout.
continue_choice=$(confirm_logout)

# Continue with the sync or cancel.
if [ "${continue_choice}" -eq 0 ] || [ "${continue_choice}" -eq 4 ]; then
  rm -f "${RSYNC_LOG}"
  display_progress

  # Clear out this plist file if it still exists.
  if [ -f "${USER_HOME}/Library/Application Support/com.gvsd.LogonScriptRun.plist" ]; then
    rm -f "${USER_HOME}/Library/Application Support/com.gvsd.LogonScriptRun.plist"
  fi

  # Log out the user.
  osascript -e 'tell application "loginwindow" to «event aevtrlgo»'
else
  echo "Logout cancelled."
  exit 1
fi