#!/bin/zsh --no-rcs
# shellcheck shell=bash

umask 077

# ============================================================
# Script Name: MOFA_Community_Microsoft_Teams_Reset.zsh
# Repository: https://github.com/cocopuff2u/MOFA/tree/main/office_reset_tools/mofa_community_maintained
# Description: Resets the Microsoft Teams
#
# Version History:
# 1.0.0 - Based on the latest available package from *Office-Reset.com*; recreated for MOFA to continue maintenance where *Office-Reset.com* left off.
# 1.0.1 - @Theile additions to use shellcheck, define PATH, and preserve Teams backgrounds. Classic Teams is dead.
# 1.0.2 - @Theile addition to read arguments with variables (INSTALL=force will always removed installed version), reset TCC. Open window for user to allow Screen recording after TCC reset.
#
# ============================================================

# Set PATH variable to SIP protected folders
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

echo "Office-Reset: Starting Reset_Teams"
autoload is-at-least

if [[ $EUID -ne 0 ]]; then
	echo "Office-Reset: This script must be run as root." >&2
	exit 1
fi

APP_NAME="Microsoft Teams"
# DOWNLOAD_URL_TEAMS="https://go.microsoft.com/fwlink/?linkid=869428" # Old Classic URL pointing to same URL as the new
DOWNLOAD_URL_TEAMS="https://go.microsoft.com/fwlink/?linkid=2249065"
INSTALLATION_RETRIES=5
OS_VERSION=$(sw_vers -productVersion)
MODE="${MODE:-reset}"
INSTALL="${INSTALL:-}" # "force" will always delete and reinstall to latest version of Teams
cleanupFailures=0
backgroundBackupDir=""

# MARK: Parse arguments

if [[ "${1:-}" == "/" ]]; then
    # jamf uses sends '/' as the first argument
    echo "shifting arguments for Jamf"
    shift 3
fi

# Read only the documented Jamf arguments. Never evaluate parameter text.
while (( $# > 0 )); do
	case "$1" in
		"") ;;
		MODE=*) MODE="${1#MODE=}" ;;
		INSTALL=*) INSTALL="${1#INSTALL=}" ;;
		reset|repair|reinstall|force) MODE="$1" ;;
		*)
			echo "Office-Reset: Unsupported argument '$1'. Use MODE=reset|repair|reinstall|force or INSTALL=force." >&2
			exit 2
			;;
	esac
	shift
done

MODE=${MODE:l}
INSTALL=${INSTALL:l}
case "$MODE" in
	reset|repair|reinstall|force) ;;
	*) echo "Office-Reset: Invalid MODE '$MODE'." >&2; exit 2 ;;
esac
case "$INSTALL" in
	""|force) ;;
	*) echo "Office-Reset: Invalid INSTALL value '$INSTALL'." >&2; exit 2 ;;
esac


# MARK: Functions

GetLoggedInUser() {
	/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk '/Name :/&&!/loginwindow/{print $3}'
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
		echo "Office-Reset: No logged-in user detected; skipping user-context command: $*" >&2
		return 1
	fi

	/bin/launchctl asuser "$LoggedInUserID" /usr/bin/sudo -H -u "$LoggedInUser" "$@"
}

safeDelete() {
	local target="$1"
	local allowed=false

	if [[ -z "$target" || "$target" != /* || "$target" == "/" ]]; then
		echo "Office-Reset: Refusing unsafe deletion target '$target'." >&2
		cleanupFailures=$((cleanupFailures + 1))
		return 1
	fi

	if [[ "$HOME" == /Users/* && "$target" == "$HOME"/* ]]; then
		allowed=true
	elif [[ ( "$TMPDIR" == /var/folders/* || "$TMPDIR" == /private/var/folders/* ) && "$target" == "$TMPDIR"/* ]]; then
		allowed=true
	elif [[ -n "$backgroundBackupDir" && "$target" == "$backgroundBackupDir" && "$backgroundBackupDir" == /private/var/tmp/mofa-teams-backgrounds.* ]]; then
		allowed=true
	else
		case "$target" in
			"/Users/Shared/OnDemandInstaller"|\
			"/Applications/Microsoft Teams.app"|\
			"/Applications/Microsoft Teams classic.app"|\
			"/Applications/Microsoft Teams (work or school).app"|\
			"/Library/Application Support/TeamsUpdaterDaemon"|\
			"/Library/Application Support/Microsoft/TeamsUpdaterDaemon"|\
			"/Library/Application Support/Teams"|\
			"/Library/Managed Preferences/com.microsoft.teams.plist"|\
			"/Library/Managed Preferences/com.microsoft.teams.helper.plist"|\
			"/Library/Preferences/com.microsoft.teams.plist"|\
			"/Library/Preferences/com.microsoft.teams.helper.plist"|\
			"/Library/Logs/Microsoft/Teams") allowed=true ;;
		esac
	fi

	if [[ "$allowed" != true ]]; then
		echo "Office-Reset: Refusing deletion outside the Teams allowlist: '$target'." >&2
		cleanupFailures=$((cleanupFailures + 1))
		return 1
	fi

	[[ -e "$target" || -L "$target" ]] || return 0
	if ! /bin/rm -rf -- "$target"; then
		cleanupFailures=$((cleanupFailures + 1))
		return 1
	fi
}

shouldReinstall() {
	[[ "$MODE" == "reinstall" || "$MODE" == "repair" || "$MODE" == "force" || "$INSTALL" == "force" ]]
}

RepairApp() {
	local DOWNLOAD_URL="$1"
	local DOWNLOAD_FOLDER="/Users/Shared/OnDemandInstaller"
	local CDN_PKG_URL CDN_PKG_NAME CDN_PKG_SIZE CDN_PKG_MB LOCAL_PKG_SIZE LOCAL_PKG_SIGNING
	if [ -d "$DOWNLOAD_FOLDER" ]; then
		safeDelete "$DOWNLOAD_FOLDER" || return 1
	fi
	/bin/mkdir -p "$DOWNLOAD_FOLDER" || return 1

	CDN_PKG_URL=$(/usr/bin/nscurl --location --head "$DOWNLOAD_URL" --dump-header - | awk '/Location/' | cut -d ' ' -f2 | tail -1 | awk '{$1=$1};1')
	if [[ -z "$CDN_PKG_URL" ]]; then
		echo "Office-Reset: Unable to resolve the Microsoft Teams package URL" >&2
		return 1
	fi
	echo "Office-Reset: Package to download is ${CDN_PKG_URL}"
	CDN_PKG_NAME=$(/usr/bin/basename "${CDN_PKG_URL}")

	CDN_PKG_SIZE=$(/usr/bin/nscurl --location --head "$DOWNLOAD_URL" --dump-header - | awk '/Content-Length:/' | cut -d ' ' -f2 | tail -1 | awk '{$1=$1};1')
	if [[ "$CDN_PKG_SIZE" != <1-> ]]; then
		echo "Office-Reset: Unable to determine a valid Teams package size" >&2
		return 1
	fi
	CDN_PKG_MB=$((CDN_PKG_SIZE / 1024 / 1024))
	echo "Office-Reset: Download package is ${CDN_PKG_MB} megabytes in size"

	echo "Office-Reset: Starting ${APP_NAME} package download"
	/usr/bin/nscurl --download --large-download --location --download-directory "$DOWNLOAD_FOLDER" "$DOWNLOAD_URL" || return 1
	echo "Office-Reset: Finished package download"

	LOCAL_PKG_SIZE=$(/usr/bin/stat -f '%z' "${DOWNLOAD_FOLDER}/${CDN_PKG_NAME}" 2>/dev/null) || return 1
	if [[ "${LOCAL_PKG_SIZE}" == "${CDN_PKG_SIZE}" ]]; then
		echo "Office-Reset: Downloaded package is wholesome"
	else
		echo "Office-Reset: Downloaded package is malformed. Local file size: ${LOCAL_PKG_SIZE}"
		echo "Office-Reset: Please manually download and install ${APP_NAME} from ${CDN_PKG_URL}"
		return 1
	fi

	LOCAL_PKG_SIGNING=$(/usr/sbin/pkgutil --check-signature "${DOWNLOAD_FOLDER}/${CDN_PKG_NAME}" | awk '/Developer ID Installer'/ | cut -d ':' -f 2 | awk '{$1=$1};1')
	if [[ "${LOCAL_PKG_SIGNING}" == "Microsoft Corporation (UBF8T346G9)" ]]; then
		echo "Office-Reset: Downloaded package is signed by Microsoft"
	else
		echo "Office-Reset: Downloaded package is not signed by Microsoft"
		echo "Office-Reset: Please manually download and install ${APP_NAME} from ${CDN_PKG_URL}"
		return 1
	fi

	echo "Office-Reset: Starting package install"
	/usr/sbin/installer -pkg "${DOWNLOAD_FOLDER}/${CDN_PKG_NAME}" -target /
	if [ $? -eq 0 ]; then
		echo "Office-Reset: Package installed successfully"
	else
		echo "Office-Reset: Package installation failed"
		echo "Office-Reset: Please manually download and install ${APP_NAME} from ${CDN_PKG_URL}"
		return 1
	fi
}

FindEntryTeamsIdentity() {
	runAsUser /usr/bin/security find-generic-password -l 'Microsoft Teams Identities Cache' 2> /dev/null 1> /dev/null
	echo $?
}

## MARK: Main
LoggedInUser=$(GetLoggedInUser)
if [[ -z "$LoggedInUser" ]] || ! SetHomeFolder "$LoggedInUser" || [[ "$HOME" != /Users/* ]]; then
	echo "Office-Reset: A valid logged-in user with a /Users home is required; no changes were made." >&2
	exit 1
fi
echo "Office-Reset: Running as: $LoggedInUser ($LoggedInUserID); Home Folder: $HOME; Mode: $MODE; Install flag: ${INSTALL:-none}"

/usr/bin/pkill -9 'Microsoft Teams*'

# MARK: Handle previous installation of Teams (if any)
appPath="/Applications/Microsoft Teams.app"
if [ -d "${appPath}" ]; then
	APP_VERSION=$(defaults read "${appPath}/Contents/Info.plist" CFBundleVersion)
	APP_BUNDLEID=$(defaults read "${appPath}/Contents/Info.plist" CFBundleIdentifier)
	echo "Office-Reset: Found version ${APP_VERSION} of ${APP_NAME} with bundle ID ${APP_BUNDLEID}"
	if [[ $INSTALL == "force" ]]; then
		echo "Office-Reset: Force reinstall of ${APP_NAME}. Removing it now"
		safeDelete "${appPath}" || exit 1
	else
		echo "Office-Reset: Leaving the installed ${APP_NAME} app bundle in place. Teams for Mac updates through MAU and its own updater."
	fi
fi
appPath="/Applications/Microsoft Teams classic.app"
if [ -d "${appPath}" ]; then
	echo "Office-Reset: Found ancient version of ${APP_NAME}: ${appPath}. Removing it now"
	safeDelete "${appPath}" || exit 1
fi
appPath="/Applications/Microsoft Teams (work or school).app"
if [ -d "${appPath}" ]; then
	echo "Office-Reset: Found ancient version of ${APP_NAME}: ${appPath}. Removing it now"
	safeDelete "${appPath}" || exit 1
fi

# MARK: Handling user-installed backgrounds
# Move backgrounds for Teams Classic (dead)
backgroundsFolder="$HOME/Library/Application Support/Microsoft/Teams/Backgrounds"
if [ -d "${backgroundsFolder}" ]; then
	echo "Office-Reset: Detected Classic backgrounds for ${APP_NAME}"
	destFolder="$HOME/Teams_Old_Backgrounds"
	orgDestFolder="${destFolder}"
	folderCounter=0
	while [ -e "${destFolder}" ]; do
		((folderCounter++))
		destFolder="${orgDestFolder}${folderCounter}"
	done
	echo "Office-Reset: moved to ${destFolder}"
	mv "${backgroundsFolder}" "${destFolder}"
	echo "Office-Reset: Classic Teams backgrounds were moved to ${destFolder}"
fi
# Preserve backgrounds
backgroundsFolder="$HOME/Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams/Backgrounds"
if [ -d "${backgroundsFolder}" ]; then
	echo "Office-Reset: Preserve backgrounds for ${APP_NAME}"
	backgroundBackupDir=$(/usr/bin/mktemp -d /private/var/tmp/mofa-teams-backgrounds.XXXXXX) || exit 1
	/bin/chmod 700 "$backgroundBackupDir" || exit 1
	if ! /usr/bin/ditto "${backgroundsFolder}" "$backgroundBackupDir/Backgrounds"; then
		echo "Office-Reset: Unable to create a private Teams background backup." >&2
		exit 1
	fi
	echo "Office-Reset: Background recovery copy staged at $backgroundBackupDir"
fi

# MARK: Remove configuration data
echo "Office-Reset: Removing configuration data for ${APP_NAME}"
safeDelete "$HOME/Library/Application Support/Teams"
safeDelete "$HOME/Library/Application Support/Microsoft/Teams"


safeDelete "$HOME/Library/Application Support/com.microsoft.teams"
safeDelete "$HOME/Library/Application Support/com.microsoft.teams.helper"

safeDelete "$HOME/Library/Application Scripts/UBF8T346G9.com.microsoft.teams"
safeDelete "$HOME/Library/Application Scripts/com.microsoft.teams2"
safeDelete "$HOME/Library/Application Scripts/com.microsoft.teams2.launcher"
safeDelete "$HOME/Library/Application Scripts/com.microsoft.teams2.notificationcenter"

safeDelete "$HOME/Library/Caches/com.microsoft.teams"
safeDelete "$HOME/Library/Caches/com.microsoft.teams.helper"
safeDelete "$HOME/Library/Cookies/com.microsoft.teams.binarycookies"
safeDelete "$HOME/Library/HTTPStorages/com.microsoft.teams.binarycookies"
safeDelete "$HOME/Library/HTTPStorages/com.microsoft.teams"
safeDelete "$HOME/Library/Logs/Microsoft Teams"
safeDelete "$HOME/Library/Logs/Microsoft Teams Helper"
safeDelete "$HOME/Library/Logs/Microsoft Teams Helper (Renderer)"
safeDelete "$HOME/Library/Saved Application State/com.microsoft.teams.savedState"
safeDelete "$HOME/Library/WebKit/com.microsoft.teams"

safeDelete "$HOME/Library/Containers/com.microsoft.teams2"
safeDelete "$HOME/Library/Containers/com.microsoft.teams2.launcher"
safeDelete "$HOME/Library/Containers/com.microsoft.teams2.notificationcenter"

safeDelete "$HOME/Library/Group Containers/UBF8T346G9.com.microsoft.teams"
safeDelete "$HOME/Library/Group Containers/UBF8T346G9.com.microsoft.oneauth"

safeDelete "/Library/Application Support/TeamsUpdaterDaemon"
safeDelete "/Library/Application Support/Microsoft/TeamsUpdaterDaemon"
safeDelete "/Library/Application Support/Teams"

safeDelete "$HOME/Library/Preferences/com.microsoft.teams.plist"
safeDelete "/Library/Managed Preferences/com.microsoft.teams.plist"
safeDelete "/Library/Preferences/com.microsoft.teams.plist"
safeDelete "$HOME/Library/Preferences/com.microsoft.teams.helper.plist"
safeDelete "/Library/Managed Preferences/com.microsoft.teams.helper.plist"
safeDelete "/Library/Preferences/com.microsoft.teams.helper.plist"

safeDelete "$TMPDIR/com.microsoft.teams"
safeDelete "$TMPDIR/com.microsoft.teams Crashes"
safeDelete "$TMPDIR/Teams"
safeDelete "$TMPDIR/Microsoft Teams Helper (Renderer)"
safeDelete "$TMPDIR/v8-compile-cache-501"

safeDelete "/Library/Logs/Microsoft/Teams"


# MARK: Extra things to clean
# Reset TCC (PPPC) for Teams
echo "Reset TCC for com.microsoft.teams2"
runAsUser /usr/bin/tccutil reset All com.microsoft.teams2 >/dev/null 2>&1 || true

# Keychain items
if [[ -n "$LoggedInUser" ]]; then
	KeychainHasLogin=$(runAsUser /usr/bin/security list-keychains 2>/dev/null | grep 'login.keychain' || true)
	if [ "$KeychainHasLogin" = "" ]; then
		echo "Office-Reset: Adding user login keychain to list"
		runAsUser /usr/bin/security list-keychains -s "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true
	fi

	echo "Display list-keychains for logged-in user"
	runAsUser /usr/bin/security list-keychains || true

	while [[ $(FindEntryTeamsIdentity) -eq 0 ]]; do
		runAsUser /usr/bin/security delete-generic-password -l 'Microsoft Teams Identities Cache' 2>/dev/null || break
	done
	runAsUser /usr/bin/security delete-generic-password -l 'Teams Safe Storage' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'Microsoft Teams (work or school) Safe Storage' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'teamsIv' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'teamsKey' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.teams.HockeySDK' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.teams.helper.HockeySDK' 2>/dev/null || true
else
	echo "Office-Reset: No logged-in user detected; skipping user keychain cleanup"
fi

# Restore backgrounds
if [[ -n "$backgroundBackupDir" && -d "$backgroundBackupDir/Backgrounds" ]]; then
	echo "Office-Reset: Restore backgrounds for ${APP_NAME}"
	backgroundRestoreParent="$HOME/Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams"
	/bin/mkdir -p "$backgroundRestoreParent" || exit 1
	if ! /usr/bin/ditto "$backgroundBackupDir/Backgrounds" "$backgroundRestoreParent/Backgrounds"; then
		echo "Office-Reset: Background restore failed; recovery copy remains at $backgroundBackupDir." >&2
		exit 1
	fi
	/usr/sbin/chown -R "$LoggedInUser" "$backgroundRestoreParent" || exit 1
	safeDelete "$backgroundBackupDir" || exit 1
fi


# MARK: Install Teams if damaged or not found
appPath="/Applications/Microsoft Teams.app"
if ! codesign -vv --deep "${appPath}"; then
	if shouldReinstall; then
		echo "Office-Reset: ${APP_NAME} is damaged or not existing so preparing for reinstallation"
		[ -e "${appPath}" ] && safeDelete "${appPath}"
	else
		echo "Office-Reset: ${APP_NAME} is damaged or missing. Reset mode will not reinstall automatically."
	fi
else
	echo "Office-Reset: Codesign passed successfully"
	APP_VERSION=$(defaults read "${appPath}/Contents/Info.plist" CFBundleVersion)
	echo "Office-Reset: The installed version of ${APP_NAME} is $APP_VERSION"
fi
folderCounter=1
while shouldReinstall && [ ! -d "${appPath}" ]; do
	echo "Office-Reset: ${APP_NAME} not installed. Trying ${folderCounter}. installation at the most $INSTALLATION_RETRIES times, now"
	if ! RepairApp "$DOWNLOAD_URL_TEAMS"; then
		echo "Office-Reset: Reinstallation attempt ${folderCounter} failed." >&2
	fi
	codesign -vv --deep "${appPath}"
	if [ $? -gt 0 ]; then
		echo "Office-Reset: The ${APP_NAME} app bundle is damaged and will be removed for reinstallation"
		[ -e "${appPath}" ] && safeDelete "${appPath}"
	else
		echo "Office-Reset: Codesign passed successfully"
		APP_VERSION=$(defaults read "${appPath}/Contents/Info.plist" CFBundleVersion)
		echo "Office-Reset: The installed version of ${APP_NAME} is now $APP_VERSION"
	fi
	[[ $folderCounter -ge $INSTALLATION_RETRIES ]] && break
	((folderCounter++))
done

if shouldReinstall && ! codesign -vv --deep "${appPath}" >/dev/null 2>&1; then
	echo "Office-Reset: ${APP_NAME} could not be installed successfully after ${INSTALLATION_RETRIES} attempts." >&2
	exit 1
fi

if ! shouldReinstall && [ ! -d "${appPath}" ]; then
	echo "Office-Reset: ${APP_NAME} is not installed. Use MODE=reinstall or INSTALL=force to reinstall it from Jamf."
fi

echo "Office-Reset: Screen recording permission for Teams may need to be re-approved in System Settings."

if (( cleanupFailures > 0 )); then
	echo "Office-Reset: Teams reset completed with ${cleanupFailures} cleanup failure(s)." >&2
	exit 1
fi

exit 0
