#!/bin/zsh

############################################################
# Save & Log Out script, to be called by an Automator app. #
############################################################

SCRIPT_VERSION="2026-09-23-1248"
USERS_BASE_DIR="${GMS_USERS_BASE_DIR:-/Users}"

# Determine ConsoleUser (the logged-in user) and that user's home directory.
CurrentUSER="${GMS_CURRENT_USER:-$( scutil <<< "show State:/Users/ConsoleUser" | awk '/Name :/ && ! /Loginwindow/ { print $3 }' )}"
# Prefer dscl to get exact NFSHomeDirectory; fall back to ~user expansion.
USER_HOME="${GMS_USER_HOME:-$(dscl . -read /Users/"${CurrentUSER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')}"
if [ -z "${USER_HOME}" ]; then
  USER_HOME="${USERS_BASE_DIR}/${CurrentUSER}"
fi
REDIRECT_STATE_PATH="${USER_HOME}/Library/Application Support/com.gvsd.RedirectState"

# Set up sync sources and destinations using the real user's home dir.
typeset -A RSYNC_PAIRS
RSYNC_PAIRS=(
  "${USER_HOME}/Library/Application Support/minecraft/saves/" "${USER_HOME}/Documents/Application Support/minecraft/saves/"
  "${USER_HOME}/Library/Application Support/minecraft/curseforge/" "${USER_HOME}/Documents/Application Support/minecraft/curseforge/"
  "${USER_HOME}/Library/Application Support/minecraft/launcher_accounts.json" "${USER_HOME}/Documents/Application Support/minecraft/"
  "${USER_HOME}/Library/Application Support/minecraft/launcher_msa_credentials.bin" "${USER_HOME}/Documents/Application Support/minecraft/"
  "${USER_HOME}/Library/Application Support/minecraft/options.txt" "${USER_HOME}/Documents/Application Support/minecraft/"
  "${USER_HOME}/Music/GarageBand/" "${USER_HOME}/Documents/GarageBand/"
  "${USER_HOME}/Twine/" "${USER_HOME}/Documents/Sync/Twine/"
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
PROG_MAIN_BUTTON="Cancel"

# Variables for sync failure dialogs.
ERROR_BAR_TITLE="Files Not Saved"
ERROR_MAIN_BUTTON="OK"

Notifier_Process=""
SYNC_PERMISSION_DENIED=0

PIPE_DIR=""
PIPE_PATH=""
WORKFLOW_LOCK_PATH="${USER_HOME}/Library/Application Support/.gvsd_workflow_lock"
WORKFLOW_LOCK_OWNED=0

#############
# Functions #
#############

cleanup_logout_runtime() {
  exec 3>&- 2>/dev/null || true

  if [ -n "${Notifier_Process}" ] && kill -0 "${Notifier_Process}" 2>/dev/null; then
    kill -TERM "${Notifier_Process}" 2>/dev/null || true
    wait "${Notifier_Process}" 2>/dev/null || true
  fi
  Notifier_Process=""

  if [ -n "${PIPE_PATH}" ]; then
    rm -f "${PIPE_PATH}"
  fi
  if [ -n "${PIPE_DIR}" ]; then
    rmdir "${PIPE_DIR}" 2>/dev/null || true
  fi
  PIPE_PATH=""
  PIPE_DIR=""
}

cleanup_logout_all() {
  cleanup_logout_runtime
  release_logout_workflow_lock
}

initialize_logout_runtime() {
  PIPE_DIR=$(mktemp -d "/tmp/gvsd-logout.XXXXXX") || return 1
  if ! chmod 700 "${PIPE_DIR}"; then
    cleanup_logout_runtime
    return 1
  fi
  PIPE_PATH="${PIPE_DIR}/notifier.pipe"
  if ! mkfifo "${PIPE_PATH}" || ! exec 3<> "${PIPE_PATH}"; then
    cleanup_logout_runtime
    return 1
  fi

  trap cleanup_logout_all EXIT
  trap 'exit 1' HUP INT TERM
  return 0
}

validate_logout_user() {
  local console_user="${GMS_CONSOLE_USER:-}"

  if [ -z "${console_user}" ]; then
    console_user=$(stat -f%Su /dev/console 2>/dev/null)
  fi

  case "${CurrentUSER}" in
    ""|loginwindow|root|*/*)
      echo "Invalid console user '${CurrentUSER}'." >&2
      return 1
      ;;
  esac

  if [ -z "${console_user}" ] || [ "${console_user}" != "${CurrentUSER}" ]; then
    echo "Captured user '${CurrentUSER}' does not match console user '${console_user}'." >&2
    return 1
  fi

  if [ "${USER_HOME}" != "${USERS_BASE_DIR}/${CurrentUSER}" ] || [ ! -d "${USER_HOME}" ] || [ -L "${USER_HOME}" ]; then
    echo "Unsafe or unavailable local home '${USER_HOME}'." >&2
    return 1
  fi

  return 0
}

acquire_logout_workflow_lock() {
  local existing_pid=""

  if [ -L "${WORKFLOW_LOCK_PATH}" ]; then
    echo "Unsafe workflow lock path ${WORKFLOW_LOCK_PATH}." >&2
    return 1
  fi

  if ! mkdir "${WORKFLOW_LOCK_PATH}" 2>/dev/null; then
    if [ ! -d "${WORKFLOW_LOCK_PATH}" ]; then
      echo "Unsafe workflow lock path ${WORKFLOW_LOCK_PATH}." >&2
      return 1
    fi
    if [ -f "${WORKFLOW_LOCK_PATH}/pid" ] && [ ! -L "${WORKFLOW_LOCK_PATH}/pid" ]; then
      existing_pid=$(<"${WORKFLOW_LOCK_PATH}/pid")
    fi
    if [[ "${existing_pid}" == <-> ]] && kill -0 "${existing_pid}" 2>/dev/null; then
      echo "Another login or logout workflow is already active for ${CurrentUSER}." >&2
      return 1
    fi
    if ! rm -rf "${WORKFLOW_LOCK_PATH}" || ! mkdir "${WORKFLOW_LOCK_PATH}"; then
      echo "A stale workflow lock could not be replaced for ${CurrentUSER}." >&2
      return 1
    fi
  fi

  WORKFLOW_LOCK_OWNED=1
  printf '%s\n' "$$" > "${WORKFLOW_LOCK_PATH}/pid"
  printf '%s\n' "logout" > "${WORKFLOW_LOCK_PATH}/operation"
  chmod 700 "${WORKFLOW_LOCK_PATH}" 2>/dev/null || true
  return 0
}

release_logout_workflow_lock() {
  if [ "${WORKFLOW_LOCK_OWNED}" -eq 1 ] && [ -n "${WORKFLOW_LOCK_PATH}" ]; then
    rm -rf "${WORKFLOW_LOCK_PATH}" 2>/dev/null || true
  fi
  WORKFLOW_LOCK_OWNED=0
}

validate_managed_redirections() {
  local state_version=""
  local network_home=""
  local folder=""
  local link_path=""
  local actual_target=""
  local expected_target=""
  local write_test=""
  local write_error=""
  local -a managed_folders=(Desktop Documents Downloads Pictures)

  if [ ! -f "${REDIRECT_STATE_PATH}" ] || [ -L "${REDIRECT_STATE_PATH}" ]; then
    echo "$(date +"%Y-%m-%d %H:%M:%S") -- Redirection preflight failed: verified login state is missing" >> "${RSYNC_LOG}"
    return 1
  fi

  state_version=$(sed -n 's/^version=//p' "${REDIRECT_STATE_PATH}" | head -n 1)
  network_home=$(sed -n 's/^network_home=//p' "${REDIRECT_STATE_PATH}" | head -n 1)
  if [ "${state_version}" != "1" ]; then
    echo "$(date +"%Y-%m-%d %H:%M:%S") -- Redirection preflight failed: state version is unsupported" >> "${RSYNC_LOG}"
    return 1
  fi
  if [ -z "${network_home}" ] || [[ "${network_home}" != /* ]] || [ "${network_home}" = "/" ] || [ "${network_home}" = "${USER_HOME}" ]; then
    echo "$(date +"%Y-%m-%d %H:%M:%S") -- Redirection preflight failed: recorded network home is invalid" >> "${RSYNC_LOG}"
    return 1
  fi

  for folder in "${managed_folders[@]}"; do
    link_path="${USER_HOME}/${folder}"
    expected_target="${network_home}/${folder}"

    if [ ! -L "${link_path}" ]; then
      echo "$(date +"%Y-%m-%d %H:%M:%S") -- Redirection preflight failed: ${link_path} is not a symlink" >> "${RSYNC_LOG}"
      return 1
    fi
    actual_target=$(readlink "${link_path}")
    if [ "${actual_target}" != "${expected_target}" ] || [ ! -d "${expected_target}" ]; then
      echo "$(date +"%Y-%m-%d %H:%M:%S") -- Redirection preflight failed: ${link_path} does not point to available target ${expected_target}" >> "${RSYNC_LOG}"
      return 1
    fi
  done

  write_error=$(mktemp "${network_home}/.gvsd_logout_write_test.XXXXXX" 2>&1)
  if [ "$?" -ne 0 ] || [ -z "${write_error}" ] || [ ! -f "${write_error}" ]; then
    echo "$(date +"%Y-%m-%d %H:%M:%S") -- Redirection preflight failed: network home is not writable: ${write_error}" >> "${RSYNC_LOG}"
    if contains_permission_denial "${write_error}"; then
      SYNC_PERMISSION_DENIED=1
      return 77
    fi
    return 1
  fi
  write_test="${write_error}"
  rm -f "${write_test}"

  echo "$(date +"%Y-%m-%d %H:%M:%S") -- Redirection preflight passed for ${network_home}" >> "${RSYNC_LOG}"
  return 0
}

shorten_path() {
  local path="${1%/}"
  local filename="${path##*/}"
  local parent="${path%/*}"
  local display="$filename"

  if [ "$parent" != "$path" ]; then
    display="${parent##*/}/${filename}"
  fi

  if [ "${#display}" -gt 72 ]; then
    display="...${display: -69}"
  fi

  printf '%s' "$display"
}

notify_bottom_message() {
  local message="${1//$'\n'/ }"
  printf '/bottom_message %s\n' "$message" >&3 2>/dev/null || true
}

contains_permission_denial() {
  printf '%s\n' "$1" | grep -Eiq 'operation not permitted|permission denied|access denied'
}

display_sync_error() {
  local message="$1"

  "${APP_PATH}" \
    -type "popup" \
    -bar_title "${ERROR_BAR_TITLE}" \
    -title "${message}" \
    -icon_path "${ICON_PATH}" \
    -main_button_label "${ERROR_MAIN_BUTTON}" \
    -always_on_top
}

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
  local source_path="${SOURCE_DIR%/}"
  local source_probe=""
  local source_probe_status=0
  local destination_error=""
  local output_dir=""
  local output_pipe=""
  local notifier_status=0
  local notifier_failed=0

  source_probe=$(ls -ld "${source_path}" 2>&1)
  source_probe_status=$?
  if [ "${source_probe_status}" -ne 0 ]; then
    if contains_permission_denial "${source_probe}"; then
      SYNC_PERMISSION_DENIED=1
      echo "$(date +"%Y-%m-%d %H:%M:%S") -- Permission denied while accessing source ${SOURCE_DIR}: ${source_probe}" >> "${RSYNC_LOG}"
      return 77
    fi
    echo "$(date +"%Y-%m-%d %H:%M:%S") -- Source does not exist; skipping ${SOURCE_DIR}" >> "${RSYNC_LOG}"
    return 0
  fi

  # Ensure destination exists (create the destination directory, not only its parent).
  destination_error=$(mkdir -p "${DEST_DIR}" 2>&1)
  if [ "$?" -ne 0 ]; then
    echo "$(date +"%Y-%m-%d %H:%M:%S") -- Failed to create destination ${DEST_DIR}: ${destination_error}" >> "${RSYNC_LOG}"
    if contains_permission_denial "${destination_error}"; then
      SYNC_PERMISSION_DENIED=1
      return 77
    fi
    return 1
  fi
  if ! mkdir -p "$(dirname "${RSYNC_LOG}")"; then
    echo "Failed to create log directory for ${RSYNC_LOG}" >&2
    return 1
  fi

  echo "Running Save & Log Out script version ${SCRIPT_VERSION}" >> "${RSYNC_LOG}"
  echo "$(date +"%Y-%m-%d %H:%M:%S") -- Sync start for ${SOURCE_DIR}" >> "${RSYNC_LOG}"
  echo "$(date +"%Y-%m-%d %H:%M:%S") -- Newest file wins; destination-only files will be preserved" >> "${RSYNC_LOG}"

  output_dir=$(mktemp -d "/tmp/gms_logout_rsync.${$}.XXXXXX") || return 1
  output_pipe="${output_dir}/output"
  if ! mkfifo "${output_pipe}"; then
    rmdir "${output_dir}" 2>/dev/null || true
    return 1
  fi

  # Capture rsync output directly so fast transfers cannot outrun the UI observer.
  {
    while IFS= read -r line; do
      printf '%s\n' "${line}" >> "${RSYNC_LOG}"
      case "${line}" in
        RSYNC_FILE:*)
          filename="${line#RSYNC_FILE:}"
          shortname=$(shorten_path "${filename}")
          notify_bottom_message "Syncing: ${shortname}"
          ;;
      esac
    done < "${output_pipe}"
  } &
  local output_pid=$!

  # Start rsync in the background and retain its exact PID for cancellation.
  rsync -avzu --out-format='RSYNC_FILE:%n' "${SOURCE_DIR}" "${DEST_DIR}" > "${output_pipe}" 2>&1 &
  local rsync_pid=$!
  local cancelled=0

  # Monitor rsync and the notifier. If the notifier disappears, cancel the rsync.
  while kill -0 "${rsync_pid}" 2>/dev/null; do
    if [ -z "${Notifier_Process}" ] || ! kill -0 "${Notifier_Process}" 2>/dev/null; then
      if [ -n "${Notifier_Process}" ]; then
        wait "${Notifier_Process}" 2>/dev/null
        notifier_status=$?
      else
        notifier_status=125
      fi
      Notifier_Process=""
      kill -TERM "${rsync_pid}" 2>/dev/null || true
      if [ "${notifier_status}" -eq 0 ]; then
        echo "$(date +"%Y-%m-%d %H:%M:%S") -- User cancelled Save & Log Out; stopping rsync ${rsync_pid}" >> "${RSYNC_LOG}"
        cancelled=1
      else
        echo "$(date +"%Y-%m-%d %H:%M:%S") -- Notifier exited unexpectedly with status ${notifier_status}; stopping rsync ${rsync_pid}" >> "${RSYNC_LOG}"
        notifier_failed=1
      fi
      break
    fi
    sleep 0.2
  done

  wait "${rsync_pid}" 2>/dev/null
  local rsync_status=$?

  # Let the output reader drain before inspecting the log for permission failures.
  wait "${output_pid}" 2>/dev/null || true
  rm -f "${output_pipe}"
  rmdir "${output_dir}" 2>/dev/null || true

  if grep -Eiq 'operation not permitted|permission denied|access denied' "${RSYNC_LOG}"; then
    SYNC_PERMISSION_DENIED=1
  fi

  if [ "${cancelled}" -eq 1 ]; then
    echo "$(date +"%Y-%m-%d %H:%M:%S") -- Sync cancelled for ${SOURCE_DIR}" >> "${RSYNC_LOG}"
    return 130
  fi

  if [ "${notifier_failed}" -eq 1 ]; then
    echo "$(date +"%Y-%m-%d %H:%M:%S") -- Save UI failed; logout stopped" >> "${RSYNC_LOG}"
    return 125
  fi

  if [ "${rsync_status}" -ne 0 ]; then
    echo "$(date +"%Y-%m-%d %H:%M:%S") -- Sync failed for ${SOURCE_DIR}; rsync status ${rsync_status}" >> "${RSYNC_LOG}"
    if [ "${SYNC_PERMISSION_DENIED}" -eq 1 ]; then
      return 77
    fi
    return "${rsync_status}"
  fi

  echo "$(date +"%Y-%m-%d %H:%M:%S") -- Sync complete for ${SOURCE_DIR}" >> "${RSYNC_LOG}"
  return 0
}

# Pop a dialog displaying an in-progress status bar for the sync, with a cancel button.
display_progress() {
  local sync_failed=0
  local sync_cancelled=0
  local permission_denied=0
  local notifier_failed=0
  local destination=""
  local sync_status=0

  # Launch the notifier and feed it from our fifo. Keep it backgrounded so we can do rsync work.
  "${APP_PATH}" \
    -type "popup" \
    -title "${PROG_TITLE}" \
    -bar_title "${PROG_BAR_TITLE}" \
    -icon_path "${ICON_PATH}" \
    -accessory_view_type "${PROG_ACCESSORY_TYPE}" \
    -accessory_view_payload "${PROG_ACCESSORY_PAYLOAD}" \
    -main_button_label "${PROG_MAIN_BUTTON}" \
    -always_on_top < "${PIPE_PATH}" &
  Notifier_Process=$!

  # Give the notifier a short moment to start before monitoring its exact PID.
  sleep 0.25

  # Run a sync for each of the listed source/destination pairs.
  for source in "${(@k)RSYNC_PAIRS}"; do
    destination="${RSYNC_PAIRS[$source]}"
    perform_rsync "${source}" "${destination}"
    sync_status=$?

    if [ "${sync_status}" -eq 77 ]; then
      permission_denied=1
      break
    fi
    if [ "${sync_status}" -eq 130 ]; then
      sync_cancelled=1
      break
    fi
    if [ "${sync_status}" -eq 125 ]; then
      notifier_failed=1
      break
    fi
    if [ "${sync_status}" -ne 0 ]; then
      sync_failed=1
    fi
  done

  # Tell the progress UI to close, and clean up.
  printf 'end\n' >&3
  exec 3>&-
  if [ -n "${Notifier_Process}" ]; then
    wait "${Notifier_Process}" 2>/dev/null || true
  fi
  Notifier_Process=""
  cleanup_logout_runtime

  if [ "${permission_denied}" -eq 1 ]; then
    echo "$(date +"%Y-%m-%d %H:%M:%S") -- File access permission was denied; logout stopped" >> "${RSYNC_LOG}"
    return 77
  fi
  if [ "${sync_cancelled}" -eq 1 ]; then
    echo "$(date +"%Y-%m-%d %H:%M:%S") -- Save & Log Out cancelled during sync" >> "${RSYNC_LOG}"
    return 130
  fi
  if [ "${notifier_failed}" -eq 1 ]; then
    echo "$(date +"%Y-%m-%d %H:%M:%S") -- Save UI failed unexpectedly; logout stopped" >> "${RSYNC_LOG}"
    return 125
  fi
  if [ "${sync_failed}" -eq 1 ]; then
    echo "$(date +"%Y-%m-%d %H:%M:%S") -- One or more sync operations failed; logout stopped" >> "${RSYNC_LOG}"
    return 1
  fi

  return 0
}

#################
# Main sequence #
#################

main() {
  local continue_choice=0
  local preflight_status=0
  local sync_status=0

  if ! validate_logout_user; then
    display_sync_error "Your files cannot be saved because the current user could not be verified. Do not log out. Ask your teacher for help."
    return 1
  fi
  if ! acquire_logout_workflow_lock; then
    display_sync_error "A login or save process is already running. Do not log out. Wait a moment and try again."
    return 1
  fi
  trap cleanup_logout_all EXIT
  trap 'exit 1' HUP INT TERM

  continue_choice=$(confirm_logout)
  if [ "${continue_choice}" -ne 0 ] && [ "${continue_choice}" -ne 4 ]; then
    echo "Logout cancelled."
    return 1
  fi

  rm -f "${RSYNC_LOG}"
  validate_managed_redirections
  preflight_status=$?
  if [ "${preflight_status}" -ne 0 ]; then
    if [ "${preflight_status}" -eq 77 ]; then
      display_sync_error "Your files were NOT saved because file access was denied. Do not log out. Ask your teacher for help."
    else
      display_sync_error "Your files cannot be saved because your network folders are not connected correctly. Do not log out. Ask your teacher for help."
    fi
    echo "Redirection preflight failed. Logout stopped; see ${RSYNC_LOG} for details."
    return "${preflight_status}"
  fi

  if ! initialize_logout_runtime; then
    display_sync_error "Your files cannot be saved because the save process could not start. Do not log out. Ask your teacher for help."
    return 1
  fi

  display_progress
  sync_status=$?

  if [ "${sync_status}" -ne 0 ]; then
    if [ "${sync_status}" -eq 77 ]; then
      display_sync_error "Your files were NOT saved because file access was denied. Do not log out. Ask your teacher for help."
    elif [ "${sync_status}" -ne 130 ]; then
      display_sync_error "Your files were NOT saved. Do not log out. Ask your teacher for help."
    fi
    echo "Save failed or was cancelled. Logout stopped; see ${RSYNC_LOG} for details."
    return "${sync_status}"
  fi

  rm -f "${USER_HOME}/Library/Application Support/com.gvsd.LogonScriptRun.plist"
  rm -f "${REDIRECT_STATE_PATH}"

  # Log out the user only after every configured sync has succeeded.
  osascript -e 'tell application "loginwindow" to «event aevtrlgo»'
}

if [[ "${ZSH_EVAL_CONTEXT}" == "toplevel" ]]; then
  main
  exit $?
fi
