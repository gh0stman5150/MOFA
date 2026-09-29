#!/bin/zsh --no-rcs

# ============================================================
# Script Name: MOFA_Community_Microsoft_AutoUpdate_Reset.zsh
# Repository: https://github.com/cocopuff2u/MOFA/tree/main/office_reset_tools/mofa_community_maintained
# Description: Resets Microsoft AutoUpdate (MAU) preferences, caches and app registrations, and
#              optionally repairs or reinstalls MAU.
#
# Version History:
# 1.0.0 - Based on the latest available package from *Office-Reset.com*; recreated for MOFA to continue maintenance where *Office-Reset.com* left off.
# 1.1.0 - MOFA refresh: recommended MAU version 4.83.26040910, validate the Jamf mode, download and
#         verify the package before removing a damaged copy, restart the MAU launchd jobs after the
#         reset, flush cfprefsd before rewriting preferences, clean the console user's temp folder,
#         register current Microsoft apps (Copilot, Quick Assist, Remote Help) and drop retired
#         Skype for Business and Defender ATP names, and return nonzero when a cleanup step fails.
#
# Jamf parameter 4 (MODE, optionally written as MODE=value):
#   reset     - reset MAU configuration only (default)
#   repair    - also reinstall MAU when it is missing, damaged or older than the recommended version
#   reinstall - same as repair
#   force     - always download and reinstall MAU, then reset its configuration
# ============================================================

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
autoload -Uz is-at-least

echo "Office-Reset: Starting postinstall for Reset_AutoUpdate"

if [[ $EUID -ne 0 ]]; then
	echo "Office-Reset: This script must be run as root." >&2
	exit 1
fi

APP_NAME="Microsoft AutoUpdate"
APP_PATH="/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app"
DOWNLOAD_URL="https://go.microsoft.com/fwlink/?linkid=830196"
# Keep in step with MSau04 in latest_raw_files/macos_standalone_latest.xml.
MAU_RECOMMENDED_VERSION="4.83.26040910"
MICROSOFT_TEAM_ID="UBF8T346G9"
MINIMUM_MACOS_VERSION="12.0"
REMOVAL_FAILURES=0
WORK_DIR=""

MODE="${4:-${MODE:-reset}}"
MODE="${MODE//[[:space:]]/}"
MODE="${MODE#[Mm][Oo][Dd][Ee]=}"
MODE=${MODE:l}
case "$MODE" in
	reset|repair|reinstall|force) ;;
	*)
		echo "Office-Reset: Unsupported mode '${MODE}'. Use reset, repair, reinstall or force." >&2
		exit 2
		;;
esac

CleanupWorkDir() {
	if [[ -n "$WORK_DIR" && "$WORK_DIR" == /private/var/tmp/mofa_reset.* && -d "$WORK_DIR" ]]; then
		/bin/rm -rf -- "$WORK_DIR"
	fi
}
trap CleanupWorkDir EXIT

FinishRun() {
	if (( REMOVAL_FAILURES > 0 )); then
		echo "Office-Reset: Completed with ${REMOVAL_FAILURES} removal failure(s)" >&2
		exit 1
	fi
	exit 0
}

GetLoggedInUser() {
	/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk '/Name :/ && !/loginwindow/ { print $3 }'
}

SetHomeFolder() {
	local target_user="$1"

	LoggedInUserID=""
	if [[ -z "$target_user" || "$target_user" == "root" || "$target_user" == "_mbsetupuser" ]]; then
		LoggedInUser=""
		HOME="/var/empty"
		return 0
	fi

	HOME=$(/usr/bin/dscl . -read "/Users/${target_user}" NFSHomeDirectory 2>/dev/null | /usr/bin/awk -F': ' 'NR==1 { print $2 }')
	if [[ -z "$HOME" && -d "/Users/${target_user}" ]]; then
		HOME="/Users/${target_user}"
	fi
	if [[ "$HOME" != /Users/?* || ! -d "$HOME" ]]; then
		echo "Office-Reset: Home folder for ${target_user} is not under /Users; skipping user data" >&2
		LoggedInUser=""
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

GetUserTempFolder() {
	local user_tmp

	user_tmp=$(runAsUser /usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || user_tmp=""
	user_tmp="${user_tmp%/}"
	if [[ "$user_tmp" == /private/var/folders/* || "$user_tmp" == /var/folders/* ]]; then
		printf '%s\n' "$user_tmp"
	else
		printf '%s\n' "/var/empty"
	fi
}

shouldReinstall() {
	[[ "$MODE" == "reinstall" || "$MODE" == "repair" || "$MODE" == "force" ]]
}

removeTarget() { # $1: rm option, $2: target
	local target="$2"

	if [[ -z "$target" || "$target" == "/" || "$target" != /* ]]; then
		echo "Office-Reset: Refusing to remove unsafe path '${target}'" >&2
		(( REMOVAL_FAILURES++ ))
		return 1
	fi
	if [[ -e "$target" || -L "$target" ]]; then
		echo "Office-Reset: Removing $target"
		if ! /bin/rm "$1" -- "$target"; then
			echo "Office-Reset: Failed to remove $target" >&2
			(( REMOVAL_FAILURES++ ))
			return 1
		fi
	else
		echo "Office-Reset: Skipping missing path $target"
	fi
}

removePathList() {
	local target
	for target in "$@"; do
		removeTarget -rf "$target"
	done
}

removeFileList() {
	local target
	for target in "$@"; do
		removeTarget -f "$target"
	done
}

bootoutJob() {
	local domain="$1"
	local plist="$2"

	if [[ ! -e "$plist" ]]; then
		echo "Office-Reset: Skipping missing launchd item $plist"
		return 0
	fi

	case "$domain" in
		gui)
			if [[ -n "$LoggedInUserID" ]]; then
				/bin/launchctl bootout "gui/${LoggedInUserID}" "$plist" >/dev/null 2>&1 || \
				/bin/launchctl unload "$plist" >/dev/null 2>&1 || true
			else
				echo "Office-Reset: No logged-in user detected; skipping gui launchd item $plist"
			fi
			;;
		system)
			/bin/launchctl bootout system "$plist" >/dev/null 2>&1 || \
			/bin/launchctl unload "$plist" >/dev/null 2>&1 || true
			;;
	esac
}

bootstrapJob() {
	local domain="$1"
	local plist="$2"

	[[ -e "$plist" ]] || return 0
	case "$domain" in
		gui)
			[[ -n "$LoggedInUserID" ]] || return 0
			/bin/launchctl bootstrap "gui/${LoggedInUserID}" "$plist" >/dev/null 2>&1 || true
			;;
		system)
			/bin/launchctl bootstrap system "$plist" >/dev/null 2>&1 || true
			;;
	esac
	echo "Office-Reset: Started launchd item $plist"
}

registerMauApp() {
	local app_path="$1"
	local app_id="$2"
	local app_domain="$3"
	local record

	if [[ ! -d "$app_path" ]]; then
		return 0
	fi

	record="{ 'Application ID' = '${app_id}';"
	if [[ -n "$app_domain" ]]; then
		record="${record} 'App Domain' = '${app_domain}' ;"
	fi
	record="${record} }"

	/usr/bin/defaults write /Library/Preferences/com.microsoft.autoupdate2 Applications -dict-add "$app_path" "$record"
}

DownloadAndVerifyPackage() {
	local pkg_url="$DOWNLOAD_URL"
	local signature
	local signature_rc

	if ! is-at-least "$MINIMUM_MACOS_VERSION" "$(/usr/bin/sw_vers -productVersion)"; then
		echo "Office-Reset: Warning: macOS is older than ${MINIMUM_MACOS_VERSION}; the current ${APP_NAME} package may not install"
	fi

	WORK_DIR=$(/usr/bin/mktemp -d /private/var/tmp/mofa_reset.XXXXXX) || WORK_DIR=""
	if [[ -z "$WORK_DIR" ]]; then
		echo "Office-Reset: Package download failed: unable to create a temporary folder" >&2
		exit 1
	fi
	PKG_PATH="${WORK_DIR}/package.pkg"

	echo "Office-Reset: Starting ${APP_NAME} package download from ${pkg_url}"
	if ! /usr/bin/curl -fsSL --retry 3 --connect-timeout 30 --max-time 3600 -o "$PKG_PATH" "$pkg_url"; then
		echo "Office-Reset: Package download failed" >&2
		exit 1
	fi
	if [[ ! -s "$PKG_PATH" ]]; then
		echo "Office-Reset: Downloaded package is malformed (empty file)" >&2
		exit 1
	fi
	echo "Office-Reset: Finished package download ($(/usr/bin/stat -f%z "$PKG_PATH") bytes)"

	signature=$(/usr/sbin/pkgutil --check-signature "$PKG_PATH" 2>&1)
	signature_rc=$?
	if (( signature_rc != 0 )) \
		|| [[ "$signature" != *"Status: signed by a developer certificate issued by Apple"* ]] \
		|| [[ "$signature" != *"Developer ID Installer: Microsoft Corporation (${MICROSOFT_TEAM_ID})"* ]]; then
		echo "Office-Reset: Downloaded package is not signed by Microsoft" >&2
		echo "Office-Reset: Please manually download and install ${APP_NAME} from ${pkg_url}" >&2
		exit 1
	fi
	if ! /usr/sbin/spctl -a -t install "$PKG_PATH" >/dev/null 2>&1; then
		echo "Office-Reset: Downloaded package is not signed in a way Gatekeeper accepts" >&2
		exit 1
	fi
	echo "Office-Reset: Downloaded package is signed by Microsoft"
}

InstallVerifiedPackage() {
	echo "Office-Reset: Starting package install"
	if /usr/sbin/installer -pkg "$PKG_PATH" -target /; then
		echo "Office-Reset: Package installed successfully"
	else
		echo "Office-Reset: Package installation failed" >&2
		echo "Office-Reset: Please manually download and install ${APP_NAME}" >&2
		exit 1
	fi
}

AppSignatureProblem() {
	local output
	local codesign_rc

	output=$(/usr/bin/codesign --verify --deep -vv "$APP_PATH" 2>&1)
	codesign_rc=$?
	if (( codesign_rc != 0 )); then
		printf '%s\n' "$output"
		return 0
	fi
	if ! /usr/bin/codesign -dv "$APP_PATH" 2>&1 | /usr/bin/grep -q "TeamIdentifier=${MICROSOFT_TEAM_ID}"; then
		printf '%s\n' "app is not signed by Microsoft team ${MICROSOFT_TEAM_ID}"
		return 0
	fi
	return 1
}

RepairApp() { # $1: "replace" removes the installed copy after the new package is verified
	DownloadAndVerifyPackage
	if [[ "$1" == "replace" ]]; then
		removePathList "$APP_PATH"
	fi
	InstallVerifiedPackage
}

## Main
LoggedInUser=$(GetLoggedInUser)
SetHomeFolder "$LoggedInUser"
USER_TMPDIR=$(GetUserTempFolder)
echo "Office-Reset: Running as: ${LoggedInUser:-<none>}; Home Folder: $HOME; Temp Folder: $USER_TMPDIR; Mode: $MODE"

echo "Office-Reset: Stopping update services"
/usr/bin/pkill -9 'Microsoft AutoUpdate'
/usr/bin/pkill -9 'Microsoft Update Assistant'
/usr/bin/pkill -9 'Microsoft AU Daemon'
/usr/bin/pkill -9 'Microsoft AU Bootstrapper'
/usr/bin/pkill -9 -f 'com.microsoft.autoupdate.helper'
/usr/bin/pkill -9 -f 'com.microsoft.autoupdate.bootstrapper.helper'

bootoutJob gui "/Library/LaunchAgents/com.microsoft.update.agent.plist"
bootoutJob gui "/Library/LaunchAgents/com.microsoft.autoupdate.helper.plist"
bootoutJob system "/Library/LaunchDaemons/com.microsoft.autoupdate.helper.plist"

echo "Office-Reset: Removing configuration data for ${APP_NAME}"
removeFileList \
	"$HOME/Library/Preferences/com.microsoft.autoupdate2.plist" \
	"$HOME/Library/Preferences/com.microsoft.autoupdate.fba.plist" \
	"/Library/Preferences/com.microsoft.autoupdate2.plist" \
	"/Library/Preferences/com.microsoft.autoupdate.fba.plist" \
	"/var/root/Library/Preferences/com.microsoft.autoupdate2.plist" \
	"/var/root/Library/Preferences/com.microsoft.autoupdate.fba.plist" \
	"$USER_TMPDIR/TelemetryUploadFilecom.microsoft.autoupdate.fba.txt" \
	"$USER_TMPDIR/TelemetryUploadFilecom.microsoft.autoupdate2.txt"

removePathList \
	"$HOME/Library/Caches/com.microsoft.autoupdate2" \
	"$HOME/Library/Caches/com.microsoft.autoupdate.fba" \
	"$HOME/Library/HTTPStorages/com.microsoft.autoupdate2" \
	"$HOME/Library/HTTPStorages/com.microsoft.autoupdate.fba" \
	"$HOME/Library/Application Support/Microsoft AU Daemon" \
	"/Library/Application Support/Microsoft/MERP2.0" \
	"$USER_TMPDIR/MSauClones" \
	"/Library/Caches/com.microsoft.autoupdate.helper" \
	"/Library/Caches/com.microsoft.autoupdate.fba" \
	"/Applications/.Microsoft Word.app.installBackup" \
	"/Applications/.Microsoft Excel.app.installBackup" \
	"/Applications/.Microsoft PowerPoint.app.installBackup" \
	"/Applications/.Microsoft Outlook.app.installBackup" \
	"/Applications/.Microsoft OneNote.app.installBackup"

/usr/bin/killall cfprefsd >/dev/null 2>&1 || true
/usr/bin/defaults write /Library/Preferences/com.microsoft.autoupdate2 AcknowledgedDataCollectionPolicy -string 'RequiredDataOnly'

if [[ "$MODE" == "force" ]]; then
	echo "Office-Reset: Force mode enabled, reinstalling ${APP_NAME}"
	RepairApp replace
elif [[ -d "$APP_PATH" ]]; then
	APP_VERSION=$(/usr/bin/defaults read "${APP_PATH}/Contents/Info.plist" CFBundleVersion 2>/dev/null)
	echo "Office-Reset: Found version ${APP_VERSION} of ${APP_NAME}"
	if [[ -n "$APP_VERSION" ]] && ! is-at-least "${MAU_RECOMMENDED_VERSION}" "$APP_VERSION"; then
		if shouldReinstall; then
			echo "Office-Reset: The installed version of ${APP_NAME} is older than the recommended version ${MAU_RECOMMENDED_VERSION}. Reinstall mode enabled, updating it now"
			RepairApp
		else
			echo "Office-Reset: The installed version of ${APP_NAME} is older than the recommended version ${MAU_RECOMMENDED_VERSION}. Reset mode will not reinstall automatically"
		fi
	fi
	echo "Office-Reset: Checking the app bundle for corruption"
	if SIGNATURE_PROBLEM=$(AppSignatureProblem); then
		echo "Office-Reset: The ${APP_NAME} app bundle is damaged and reporting error ${SIGNATURE_PROBLEM}"
		if shouldReinstall; then
			echo "Office-Reset: The ${APP_NAME} app bundle is damaged and will be reinstalled"
			RepairApp replace
		else
			echo "Office-Reset: The ${APP_NAME} app bundle is damaged. Reset mode will not reinstall automatically"
		fi
	else
		echo "Office-Reset: Codesign passed successfully"
	fi
else
	echo "Office-Reset: ${APP_NAME} was not found in the default location"
	if shouldReinstall; then
		echo "Office-Reset: Reinstall mode enabled, installing ${APP_NAME}"
		RepairApp
	fi
fi

echo "Office-Reset: Creating new preferences"
# The "2019" suffixes are Microsoft's current MAU application IDs.
registerMauApp "$APP_PATH" "MSau04" "com.microsoft.office"
registerMauApp "/Applications/Microsoft Word.app" "MSWD2019" "com.microsoft.office"
registerMauApp "/Applications/Microsoft Excel.app" "XCEL2019" "com.microsoft.office"
registerMauApp "/Applications/Microsoft PowerPoint.app" "PPT32019" "com.microsoft.office"
registerMauApp "/Applications/Microsoft Outlook.app" "OPIM2019" "com.microsoft.office"
registerMauApp "/Applications/Microsoft OneNote.app" "ONMC2019" "com.microsoft.office"
registerMauApp "/Applications/OneDrive.app" "ONDR18" "com.microsoft.office"
registerMauApp "/Applications/Microsoft Teams.app" "TEAMS21" "com.microsoft.office"
registerMauApp "/Applications/Microsoft Teams (work or school).app" "TEAMS21" "com.microsoft.office"
registerMauApp "/Applications/Microsoft Teams (work preview).app" "TEAMS21" "com.microsoft.office"
registerMauApp "/Applications/Microsoft Edge.app" "EDGE01"
registerMauApp "/Applications/Microsoft Edge Beta.app" "EDBT01"
registerMauApp "/Applications/Microsoft Edge Canary.app" "EDCN01"
registerMauApp "/Applications/Microsoft Edge Dev.app" "EDDV01"
registerMauApp "/Applications/Windows App.app" "MSRD10"
registerMauApp "/Applications/Microsoft Remote Desktop.app" "MSRD10"
registerMauApp "/Applications/Company Portal.app" "IMCP01"
registerMauApp "/Applications/Microsoft Defender.app" "WDAV00"
registerMauApp "/Applications/Microsoft 365 Copilot.app" "MSCP10"
registerMauApp "/Applications/Microsoft Quick Assist.app" "MSQA01"
registerMauApp "/Applications/Microsoft Remote Help.app" "MSRH01"
/usr/bin/killall cfprefsd >/dev/null 2>&1 || true

echo "Office-Reset: Restarting update services"
bootstrapJob system "/Library/LaunchDaemons/com.microsoft.autoupdate.helper.plist"
bootstrapJob gui "/Library/LaunchAgents/com.microsoft.update.agent.plist"
bootstrapJob gui "/Library/LaunchAgents/com.microsoft.autoupdate.helper.plist"

FinishRun
