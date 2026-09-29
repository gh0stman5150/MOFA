#!/bin/zsh --no-rcs
# shellcheck shell=bash

# ============================================================
# Script Name: MOFA_Community_Microsoft_Teams_Removal_Reinstall.zsh
# Repository: https://github.com/cocopuff2u/MOFA/tree/main/office_reset_tools/mofa_community_maintained
# Description: Resets Microsoft Teams user data, or completely removes Teams and
#              reinstalls it from the official Microsoft source.
#
# Version History:
# 1.0.0 - Initial community-maintained release. Combines the Teams reset cleanup
#         scope with the more robust Microsoft 365 installer download and
#         verification flow.
# 1.1.0 - Absorbs the retired MOFA_Community_Microsoft_Teams_Reset.zsh as MODE=reset
#         (console user only, no download, installed app kept). Custom Teams
#         backgrounds are backed up to ~/Teams_Backgrounds_Backup in every mode.
#         Installer checks now require Apple's "signed" status and Gatekeeper
#         acceptance, the installed app must carry Microsoft's team ID, and
#         cleanup failures return a nonzero exit.
#
# Jamf parameters (from $4, KEY=value; unsupported keys are ignored):
#   MODE=reinstall (default) - remove Teams for all users, then reinstall it.
#                              "repair" and "force" are accepted as aliases.
#   MODE=reset               - remove the console user's Teams data only.
#   DOWNLOAD_URL_TEAMS, INSTALLATION_RETRIES, DOWNLOAD_TIMEOUT, WAIT_ATTEMPTS,
#   WAIT_DELAY, CLEAN_ALL_USERS (reinstall mode only).
# ============================================================

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

setopt PIPE_FAIL

autoload -Uz is-at-least

LOG_FILE="/var/log/MOFA_Community_Microsoft_Teams_Removal_Reinstall.log"
LOG_TAG="MOFA Teams Remove/Reinstall"
SCRIPT_VERSION="1.1.0"

APP_NAME="Microsoft Teams"
EXPECTED_APP_PATH="/Applications/Microsoft Teams.app"
DOWNLOAD_URL_TEAMS="https://go.microsoft.com/fwlink/?linkid=2249065"
MICROSOFT_TEAM_ID="UBF8T346G9"
EXPECTED_INSTALLER_SIGNER="Microsoft Corporation (${MICROSOFT_TEAM_ID})"
MINIMUM_MACOS_VERSION="13.0"

INSTALLATION_RETRIES=3
DOWNLOAD_TIMEOUT=900
WAIT_ATTEMPTS=20
WAIT_DELAY=3
CLEAN_ALL_USERS="true"
MODE="reinstall"

TEMP_DIR=""
PKG_PATH=""
LoggedInUser=""
LoggedInUserID=""
HOME=""
CLEANUP_FAILURES=0
BACKGROUND_BACKUP_DIR=""

log() {
  local msg="$1"
  local ts

  ts="$(/bin/date '+%Y-%m-%d %H:%M:%S')"
  /bin/echo "$ts [${LOG_TAG}] $msg"
  /usr/bin/logger -t "$LOG_TAG" "$msg" 2>/dev/null || true
}

warn() {
  log "WARN: $1"
}

fail() {
  log "ERROR: $1"
}

ensure_logging() {
  /bin/mkdir -p "$(/usr/bin/dirname "$LOG_FILE")" >/dev/null 2>&1 || true
  /usr/bin/touch "$LOG_FILE" >/dev/null 2>&1 || true
  /bin/chmod 600 "$LOG_FILE" >/dev/null 2>&1 || true
  exec > >(/usr/bin/tee -a "$LOG_FILE") 2>&1
}

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    /bin/rm -rf -- "$TEMP_DIR" >/dev/null 2>&1 || true
  fi
  if [[ -n "$BACKGROUND_BACKUP_DIR" && -d "$BACKGROUND_BACKUP_DIR" ]]; then
    /bin/rm -rf -- "$BACKGROUND_BACKUP_DIR" >/dev/null 2>&1 || true
  fi
}

to_lower() {
  printf '%s\n' "$1" | /usr/bin/tr '[:upper:]' '[:lower:]'
}

is_true() {
  case "$(to_lower "$1")" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

parse_arguments() {
  local key
  local value

  if [[ "${1:-}" == "/" ]]; then
    log "Shifting Jamf-style leading arguments."
    shift 3
  fi

  while [[ $# -gt 0 ]]; do
    case "$(to_lower "$1")" in
      reset|reinstall|repair|force)
        MODE="$1"
        log "Configured MODE via script argument."
        shift 1
        continue
        ;;
    esac
    if [[ "$1" == *=* ]]; then
      key="${1%%=*}"
      value="${1#*=}"

      case "$key" in
        MODE|DOWNLOAD_URL_TEAMS|INSTALLATION_RETRIES|DOWNLOAD_TIMEOUT|WAIT_ATTEMPTS|WAIT_DELAY|CLEAN_ALL_USERS)
          typeset -g "${key}=${value}"
          log "Configured ${key} via script argument."
          ;;
        *)
          warn "Ignoring unsupported argument: $key"
          ;;
      esac
    fi
    shift 1
  done

  MODE="$(to_lower "${MODE//[[:space:]]/}")"
  case "$MODE" in
    reset|reinstall) ;;
    repair|force) MODE="reinstall" ;;
    *)
      fail "Unsupported MODE '${MODE}'. Use reset or reinstall."
      exit 2
      ;;
  esac

  [[ "$INSTALLATION_RETRIES" == <-> ]] || INSTALLATION_RETRIES=3
  [[ "$DOWNLOAD_TIMEOUT" == <-> ]] || DOWNLOAD_TIMEOUT=900
  [[ "$WAIT_ATTEMPTS" == <-> ]] || WAIT_ATTEMPTS=20
  [[ "$WAIT_DELAY" == <-> ]] || WAIT_DELAY=3

  (( INSTALLATION_RETRIES > 0 )) || INSTALLATION_RETRIES=3
  (( DOWNLOAD_TIMEOUT > 0 )) || DOWNLOAD_TIMEOUT=900
  (( WAIT_ATTEMPTS > 0 )) || WAIT_ATTEMPTS=20
  (( WAIT_DELAY >= 0 )) || WAIT_DELAY=3
}

GetLoggedInUser() {
  /usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk '/Name :/ && !/loginwindow/ && $3 != "root" && $3 != "_mbsetupuser" { print $3 }'
}

SetHomeFolder() {
  local target_user="$1"

  LoggedInUserID=""
  if [[ -z "$target_user" ]]; then
    HOME="/var/empty"
    return 0
  fi

  HOME=$(/usr/bin/dscl . -read "/Users/${target_user}" NFSHomeDirectory 2>/dev/null | /usr/bin/awk -F': ' 'NR==1 { print $2 }')
  if [[ -z "$HOME" && -d "/Users/${target_user}" ]]; then
    HOME="/Users/${target_user}"
  fi
  if [[ -z "$HOME" ]]; then
    HOME="/var/empty"
    return 1
  fi

  LoggedInUserID=$(/usr/bin/id -u "$target_user" 2>/dev/null)
}

runAsUser() {
  if [[ -z "$LoggedInUser" || -z "$LoggedInUserID" ]]; then
    warn "No logged-in user detected; skipping user-context command: $*"
    return 1
  fi

  /bin/launchctl asuser "$LoggedInUserID" /usr/bin/sudo -H -u "$LoggedInUser" "$@"
}

require_supported_macos() {
  local os_version

  os_version="$(/usr/bin/sw_vers -productVersion)"
  if ! is-at-least "$MINIMUM_MACOS_VERSION" "$os_version"; then
    fail "${APP_NAME} reinstall requires macOS ${MINIMUM_MACOS_VERSION} or newer. Detected macOS ${os_version}."
    exit 1
  fi

  log "macOS ${os_version} satisfies the ${APP_NAME} minimum requirement of ${MINIMUM_MACOS_VERSION}."
}

download_source_to_path() {
  local source="$1"
  local destination="$2"

  /usr/bin/curl \
    --fail \
    --silent \
    --show-error \
    --location \
    --connect-timeout 30 \
    --retry 5 \
    --retry-delay 10 \
    --max-time "$DOWNLOAD_TIMEOUT" \
    --output "$destination" \
    "$source"
}

download_pkg() {
  TEMP_DIR="$(/usr/bin/mktemp -d /private/var/tmp/teams-remove-reinstall.XXXXXX)" || {
    fail "Unable to create a temporary working directory."
    return 1
  }
  PKG_PATH="$TEMP_DIR/MicrosoftTeams.pkg"

  log "Downloading ${APP_NAME} package from ${DOWNLOAD_URL_TEAMS}"
  if ! download_source_to_path "$DOWNLOAD_URL_TEAMS" "$PKG_PATH"; then
    fail "Failed to download ${APP_NAME} package from ${DOWNLOAD_URL_TEAMS}"
    return 1
  fi

  if [[ ! -s "$PKG_PATH" ]]; then
    fail "Downloaded package is empty: $PKG_PATH"
    return 1
  fi

  log "Downloaded ${APP_NAME} package to $PKG_PATH"
}

verify_pkg_signature() {
  local signature_output

  signature_output="$(/usr/sbin/pkgutil --check-signature "$PKG_PATH" 2>&1)"
  if [[ $? -eq 0 \
    && "$signature_output" == *"Status: signed by a developer certificate issued by Apple"* \
    && "$signature_output" == *"Developer ID Installer: ${EXPECTED_INSTALLER_SIGNER}"* ]]; then
    if /usr/sbin/spctl -a -t install "$PKG_PATH" >/dev/null 2>&1; then
      log "Installer signature verified for ${EXPECTED_INSTALLER_SIGNER}."
      return 0
    fi
    fail "Gatekeeper rejected the downloaded ${APP_NAME} package."
    return 1
  fi

  warn "$signature_output"
  fail "Downloaded package was not signed by ${EXPECTED_INSTALLER_SIGNER}."
  return 1
}

bootoutJob() {
  local domain="$1"
  local plist_path="$2"

  [[ -e "$plist_path" ]] || return 0

  /bin/launchctl bootout "$domain" "$plist_path" >/dev/null 2>&1 \
    || /bin/launchctl unload "$plist_path" >/dev/null 2>&1 \
    || true
}

remove_path() {
  local target="$1"

  [[ -n "$target" ]] || return 0
  [[ -e "$target" || -L "$target" ]] || return 0

  if [[ "$target" != /?* ]]; then
    warn "Refusing to remove unsafe path: $target"
    (( CLEANUP_FAILURES++ ))
    return 1
  fi

  if /bin/rm -rf -- "$target" >/dev/null 2>&1; then
    log "Removed $target"
  else
    warn "Failed to remove $target"
    (( CLEANUP_FAILURES++ ))
  fi
}

home_cleanup_allowed() {
  local target_home="$1"

  [[ -n "$target_home" ]] || return 1
  [[ "$target_home" != "/" ]] || return 1
  [[ "$target_home" != "/Users" ]] || return 1
  [[ "$target_home" != "/Users/Shared" ]] || return 1
  [[ "$target_home" != "/var/empty" ]] || return 1
  [[ -d "$target_home" ]]
}

terminate_teams_processes() {
  local process_name

  log "Stopping running ${APP_NAME} processes."
  for process_name in \
    'Microsoft Teams' \
    'Microsoft Teams Helper' \
    'Microsoft Teams WebView' \
    'MSTeams' \
    'TeamsUpdaterDaemon' \
    'com.microsoft.teams2' \
    'com.microsoft.teams2.launcher' \
    'com.microsoft.teams2.notificationcenter'; do
    /usr/bin/pkill -9 "$process_name" >/dev/null 2>&1 || true
  done
}

backup_teams_backgrounds() {
  local backgrounds_folder="$HOME/Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/Backgrounds"

  [[ -n "$LoggedInUser" && -d "$backgrounds_folder" ]] || return 0
  BACKGROUND_BACKUP_DIR="$(/usr/bin/mktemp -d /private/var/tmp/mofa-teams-backgrounds.XXXXXX)" || {
    fail "Unable to create a private Teams background backup."
    exit 1
  }
  if ! /usr/bin/ditto "$backgrounds_folder" "$BACKGROUND_BACKUP_DIR/Backgrounds"; then
    fail "Unable to back up Teams backgrounds; no changes were made."
    exit 1
  fi
  log "Staged custom Teams backgrounds for ${LoggedInUser}."
}

restore_teams_backgrounds() {
  local destination="$HOME/Teams_Backgrounds_Backup"
  local counter=0

  [[ -n "$BACKGROUND_BACKUP_DIR" && -d "$BACKGROUND_BACKUP_DIR/Backgrounds" ]] || return 0
  while [[ -e "$destination" ]]; do
    (( counter++ ))
    destination="$HOME/Teams_Backgrounds_Backup${counter}"
  done

  # Copy into the user's home rather than recreating the Teams container as root.
  if /usr/bin/ditto "$BACKGROUND_BACKUP_DIR/Backgrounds" "$destination" \
    && /usr/sbin/chown -R "$LoggedInUser" "$destination"; then
    log "Custom Teams backgrounds were saved to ${destination}. Re-add them in Teams > Settings > Appearance."
  else
    warn "Unable to save Teams backgrounds to ${destination}."
    (( CLEANUP_FAILURES++ ))
  fi
}

cleanup_user_temp_paths() {
  local user_tmp

  [[ -n "$LoggedInUser" ]] || return 0
  user_tmp="$(runAsUser /usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"
  user_tmp="${user_tmp%/}"
  [[ "$user_tmp" == /private/var/folders/* || "$user_tmp" == /var/folders/* ]] || return 0

  remove_path "$user_tmp/com.microsoft.teams"
  remove_path "$user_tmp/com.microsoft.teams Crashes"
  remove_path "$user_tmp/com.microsoft.teams2"
  remove_path "$user_tmp/Teams"
  remove_path "$user_tmp/Microsoft Teams Helper (Renderer)"
  remove_path "$user_tmp/v8-compile-cache-${LoggedInUserID}"
}

cleanup_user_paths() {
  local target_user="$1"
  local target_home="$2"
  local target_path
  local -a target_paths

  if ! home_cleanup_allowed "$target_home"; then
    warn "Skipping cleanup for unsafe or unavailable home path: ${target_user:-unknown} -> ${target_home:-unset}"
    return 0
  fi

  log "Removing ${APP_NAME} data for user ${target_user} at ${target_home}"

  target_paths=(
    "$target_home/Library/Application Support/Teams"
    "$target_home/Library/Application Support/Microsoft/Teams"
    "$target_home/Library/Application Support/com.microsoft.teams"
    "$target_home/Library/Application Support/com.microsoft.teams.helper"
    "$target_home/Library/Application Scripts/UBF8T346G9.com.microsoft.teams"
    "$target_home/Library/Application Scripts/com.microsoft.teams2"
    "$target_home/Library/Application Scripts/com.microsoft.teams2.launcher"
    "$target_home/Library/Application Scripts/com.microsoft.teams2.notificationcenter"
    "$target_home/Library/Caches/com.microsoft.teams"
    "$target_home/Library/Caches/com.microsoft.teams.helper"
    "$target_home/Library/Caches/com.microsoft.teams2"
    "$target_home/Library/Caches/com.microsoft.teams2.launcher"
    "$target_home/Library/Caches/com.microsoft.teams2.notificationcenter"
    "$target_home/Library/Cookies/com.microsoft.teams.binarycookies"
    "$target_home/Library/HTTPStorages/com.microsoft.teams"
    "$target_home/Library/HTTPStorages/com.microsoft.teams.binarycookies"
    "$target_home/Library/HTTPStorages/com.microsoft.teams2"
    "$target_home/Library/Logs/Microsoft Teams"
    "$target_home/Library/Logs/Microsoft Teams Helper"
    "$target_home/Library/Logs/Microsoft Teams Helper (Renderer)"
    "$target_home/Library/Preferences/com.microsoft.teams.plist"
    "$target_home/Library/Preferences/com.microsoft.teams.helper.plist"
    "$target_home/Library/Preferences/com.microsoft.teams2.plist"
    "$target_home/Library/Saved Application State/com.microsoft.teams.savedState"
    "$target_home/Library/Saved Application State/com.microsoft.teams2.savedState"
    "$target_home/Library/WebKit/com.microsoft.teams"
    "$target_home/Library/WebKit/com.microsoft.teams2"
    "$target_home/Library/Containers/com.microsoft.teams2"
    "$target_home/Library/Containers/com.microsoft.teams2.launcher"
    "$target_home/Library/Containers/com.microsoft.teams2.notificationcenter"
    "$target_home/Library/Group Containers/UBF8T346G9.com.microsoft.teams"
  )

  for target_path in "${target_paths[@]}"; do
    remove_path "$target_path"
  done
}

cleanup_logged_in_user_security_state() {
  if [[ -z "$LoggedInUser" || -z "$LoggedInUserID" ]]; then
    log "No logged-in user detected; skipping TCC and keychain cleanup."
    return 0
  fi

  log "Resetting TCC entries for ${APP_NAME} for ${LoggedInUser}."
  runAsUser /usr/bin/tccutil reset All com.microsoft.teams2 >/dev/null 2>&1 || true
  runAsUser /usr/bin/tccutil reset All com.microsoft.teams >/dev/null 2>&1 || true

  if [[ -n "$HOME" ]]; then
    local -a keychain_search_list
    keychain_search_list=("${(@f)$(runAsUser /usr/bin/security list-keychains -d user 2>/dev/null | /usr/bin/sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')}")
    if [[ ${keychain_search_list[(I)*login.keychain*]} -eq 0 ]]; then
      log "Adding login keychain to the existing search list for ${LoggedInUser}."
      runAsUser /usr/bin/security list-keychains -d user -s "$HOME/Library/Keychains/login.keychain-db" "${(@)keychain_search_list:#}" >/dev/null 2>&1 || true
    fi
  fi

  local attempts=0
  while runAsUser /usr/bin/security find-generic-password -l 'Microsoft Teams Identities Cache' >/dev/null 2>&1; do
    (( attempts++ < 50 )) || break
    runAsUser /usr/bin/security delete-generic-password -l 'Microsoft Teams Identities Cache' >/dev/null 2>&1 || break
  done

  runAsUser /usr/bin/security delete-generic-password -l 'Teams Safe Storage' >/dev/null 2>&1 || true
  runAsUser /usr/bin/security delete-generic-password -l 'Microsoft Teams Safe Storage' >/dev/null 2>&1 || true
  runAsUser /usr/bin/security delete-generic-password -l 'Microsoft Teams (work or school) Safe Storage' >/dev/null 2>&1 || true
  runAsUser /usr/bin/security delete-generic-password -l 'teamsIv' >/dev/null 2>&1 || true
  runAsUser /usr/bin/security delete-generic-password -l 'teamsKey' >/dev/null 2>&1 || true
  runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.teams.HockeySDK' >/dev/null 2>&1 || true
  runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.teams.helper.HockeySDK' >/dev/null 2>&1 || true
}

cleanup_target_users() {
  local target_user
  local target_home
  local ds_user
  local ds_uid

  if is_true "$CLEAN_ALL_USERS"; then
    while IFS=$'\t' read -r target_user target_home; do
      [[ -n "$target_user" ]] || continue
      cleanup_user_paths "$target_user" "$target_home"
    done < <(
      while IFS=$'\t' read -r ds_user ds_uid; do
        target_home=$(/usr/bin/dscl . -read "/Users/${ds_user}" NFSHomeDirectory 2>/dev/null | /usr/bin/awk -F': ' 'NR==1 { print $2 }')
        if [[ -z "$target_home" && -d "/Users/${ds_user}" ]]; then
          target_home="/Users/${ds_user}"
        fi
        printf '%s\t%s\n' "$ds_user" "$target_home"
      done < <(/usr/bin/dscl . -list /Users UniqueID 2>/dev/null | /usr/bin/awk '$2 >= 500 && $1 != "nobody" { print $1 "\t" $2 }')
    )
  elif [[ -n "$LoggedInUser" ]]; then
    cleanup_user_paths "$LoggedInUser" "$HOME"
  else
    log "CLEAN_ALL_USERS is false and no logged-in user was detected; no user data was removed."
  fi

  cleanup_logged_in_user_security_state
}

cleanup_system_paths() { # $1: "keep_app" keeps the current Teams app (reset mode)
  local target_path
  local -a system_paths

  log "Removing system-wide ${APP_NAME} components."
  bootoutJob system "/Library/LaunchDaemons/com.microsoft.teams.TeamsUpdaterDaemon.plist"

  system_paths=()
  if [[ "$1" != "keep_app" ]]; then
    system_paths+=(
      "/Applications/Microsoft Teams.app"
      "/Applications/Microsoft Teams (work preview).app"
    )
  fi
  system_paths+=(
    "/Applications/Microsoft Teams classic.app"
    "/Applications/Microsoft Teams (work or school).app"
    "/Library/Application Support/TeamsUpdaterDaemon"
    "/Library/Application Support/Microsoft/TeamsUpdaterDaemon"
    "/Library/Application Support/Teams"
    "/Library/LaunchDaemons/com.microsoft.teams.TeamsUpdaterDaemon.plist"
    "/Library/Logs/Microsoft/Teams"
    "/Library/Managed Preferences/com.microsoft.teams.plist"
    "/Library/Managed Preferences/com.microsoft.teams.helper.plist"
    "/Library/Preferences/com.microsoft.teams.plist"
    "/Library/Preferences/com.microsoft.teams.helper.plist"
    "/Library/Preferences/com.microsoft.teams2.plist"
  )

  for target_path in "${system_paths[@]}"; do
    remove_path "$target_path"
  done
}

app_is_healthy() {
  local info_plist
  local bundle_version

  [[ -d "$EXPECTED_APP_PATH" ]] || return 1
  /usr/bin/codesign -vv --deep "$EXPECTED_APP_PATH" >/dev/null 2>&1 || return 1
  /usr/bin/codesign -dv "$EXPECTED_APP_PATH" 2>&1 | /usr/bin/grep -q "TeamIdentifier=${MICROSOFT_TEAM_ID}" || return 1

  info_plist="$EXPECTED_APP_PATH/Contents/Info.plist"
  [[ -f "$info_plist" ]] || return 1

  bundle_version=$(/usr/bin/defaults read "$info_plist" CFBundleVersion 2>/dev/null || true)
  [[ -n "$bundle_version" ]]
}

wait_for_app() {
  local attempt

  for ((attempt = 1; attempt <= WAIT_ATTEMPTS; attempt++)); do
    if app_is_healthy; then
      return 0
    fi
    /bin/sleep "$WAIT_DELAY"
  done

  return 1
}

log_installed_app_details() {
  local info_plist
  local bundle_id
  local bundle_version

  info_plist="$EXPECTED_APP_PATH/Contents/Info.plist"
  bundle_id=$(/usr/bin/defaults read "$info_plist" CFBundleIdentifier 2>/dev/null || printf 'unknown')
  bundle_version=$(/usr/bin/defaults read "$info_plist" CFBundleVersion 2>/dev/null || printf 'unknown')

  log "${APP_NAME} installed successfully. Bundle ID: ${bundle_id}; Version: ${bundle_version}"
}

install_teams() {
  local attempt

  for ((attempt = 1; attempt <= INSTALLATION_RETRIES; attempt++)); do
    log "Starting ${APP_NAME} install attempt ${attempt} of ${INSTALLATION_RETRIES}."

    if /usr/sbin/installer -pkg "$PKG_PATH" -target /; then
      if wait_for_app; then
        log_installed_app_details
        return 0
      fi
      warn "${APP_NAME} installer completed, but the app did not become healthy in time."
    else
      warn "${APP_NAME} installer returned a non-zero status on attempt ${attempt}."
    fi

    remove_path "$EXPECTED_APP_PATH"
  done

  return 1
}

finish() {
  if (( CLEANUP_FAILURES > 0 )); then
    fail "${APP_NAME} ${MODE} completed with ${CLEANUP_FAILURES} cleanup failure(s)."
    exit 1
  fi
  exit 0
}

run_reset() {
  if [[ -z "$LoggedInUser" || -z "$LoggedInUserID" || "$HOME" != /Users/?* ]]; then
    fail "A valid logged-in user with a /Users home is required for MODE=reset; no changes were made."
    exit 1
  fi

  backup_teams_backgrounds
  terminate_teams_processes
  cleanup_user_paths "$LoggedInUser" "$HOME"
  remove_path "$HOME/Library/Group Containers/UBF8T346G9.com.microsoft.oneauth"
  cleanup_user_temp_paths
  cleanup_logged_in_user_security_state
  cleanup_system_paths keep_app
  restore_teams_backgrounds

  if [[ ! -d "$EXPECTED_APP_PATH" ]]; then
    log "${APP_NAME} is not installed. Use MODE=reinstall to install it from Jamf."
  fi
  log "${APP_NAME} reset completed."
  log "Screen Recording and other Teams permissions may need to be re-approved in System Settings."
  finish
}

run_reinstall() {
  require_supported_macos

  if ! download_pkg; then
    exit 1
  fi

  if ! verify_pkg_signature; then
    exit 1
  fi

  backup_teams_backgrounds
  terminate_teams_processes
  cleanup_target_users
  cleanup_user_temp_paths
  cleanup_system_paths
  restore_teams_backgrounds

  if install_teams; then
    log "${APP_NAME} removal and reinstall completed."
    log "Screen Recording and other Teams permissions may need to be re-approved in System Settings."
    finish
  fi

  fail "${APP_NAME} reinstall failed after ${INSTALLATION_RETRIES} attempts."
  exit 1
}

main() {
  trap cleanup EXIT INT TERM

  ensure_logging
  parse_arguments "$@"
  log "Beginning ${APP_NAME} ${MODE} (script version: ${SCRIPT_VERSION})."

  if [[ "$EUID" -ne 0 ]]; then
    fail "This script must be run as root."
    exit 1
  fi

  LoggedInUser="$(GetLoggedInUser)"
  SetHomeFolder "$LoggedInUser"
  log "Console user: ${LoggedInUser:-none}; Home Folder: ${HOME:-unknown}; Mode: ${MODE}; Clean all users: ${CLEAN_ALL_USERS}"

  if [[ "$MODE" == "reset" ]]; then
    run_reset
  fi
  run_reinstall
}

if [[ "${(%):-%N}" == "$0" ]]; then
  main "$@"
fi

