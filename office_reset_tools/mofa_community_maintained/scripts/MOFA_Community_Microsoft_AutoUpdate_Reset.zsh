#!/bin/zsh --no-rcs

# ============================================================
# Script Name: MOFA_Community_Microsoft_AutoUpdate_Reset.zsh
# Repository: https://github.com/cocopuff2u/MOFA/tree/main/office_reset_tools/mofa_community_maintained
# Description: Resets the Microsoft AutoUpdate
#
# Version History:
# 1.0.0 - Based on the latest available package from *Office-Reset.com*; recreated for MOFA to continue maintenance where *Office-Reset.com* left off.
#
# ============================================================

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

echo "Office-Reset: Starting postinstall for Reset_AutoUpdate"
autoload is-at-least

if [[ $EUID -ne 0 ]]; then
	echo "Office-Reset: This script must be run as root." >&2
	exit 1
fi

APP_NAME="Microsoft AutoUpdate"
DOWNLOAD_URL="https://go.microsoft.com/fwlink/?linkid=830196"
MAU_RECOMMENDED_VERSION="4.73.24071426"
MODE="${4:-${MODE:-reset}}"
MODE=${MODE:l}

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

shouldReinstall() {
	[[ "$MODE" == "reinstall" || "$MODE" == "repair" || "$MODE" == "force" ]]
}

removePathList() {
	local target
	for target in "$@"; do
		if [[ -e "$target" || -L "$target" ]]; then
			echo "Office-Reset: Removing $target"
			/bin/rm -rf -- "$target"
		else
			echo "Office-Reset: Skipping missing path $target"
		fi
	done
}

removeFileList() {
	local target
	for target in "$@"; do
		if [[ -e "$target" || -L "$target" ]]; then
			echo "Office-Reset: Removing $target"
			/bin/rm -f -- "$target"
		else
			echo "Office-Reset: Skipping missing file $target"
		fi
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

RepairApp() {
	DOWNLOAD_FOLDER="/Users/Shared/OnDemandInstaller/"
	if [ -d "$DOWNLOAD_FOLDER" ]; then
		rm -rf "$DOWNLOAD_FOLDER"
	fi
	mkdir -p "$DOWNLOAD_FOLDER"

	CDN_PKG_URL=$(/usr/bin/nscurl --location --head $DOWNLOAD_URL --dump-header - | awk '/Location/' | cut -d ' ' -f2 | tail -1 | awk '{$1=$1};1')
	echo "Office-Reset: Package to download is ${CDN_PKG_URL}"
	CDN_PKG_NAME=$(/usr/bin/basename "${CDN_PKG_URL}")

	CDN_PKG_SIZE=$(/usr/bin/nscurl --location --head $DOWNLOAD_URL --dump-header - | awk '/Content-Length/' | cut -d ' ' -f2 | tail -1 | awk '{$1=$1};1')
	CDN_PKG_MB=$(/bin/expr ${CDN_PKG_SIZE} / 1000 / 1000)
	echo "Office-Reset: Download package is ${CDN_PKG_MB} megabytes in size"

	echo "Office-Reset: Starting ${APP_NAME} package download"
	if ! /usr/bin/nscurl --background --download --large-download --location --download-directory "$DOWNLOAD_FOLDER" "$DOWNLOAD_URL"; then
		echo "Office-Reset: Package download failed" >&2
		exit 1
	fi
	echo "Office-Reset: Finished package download"

	LOCAL_PKG_SIZE=$(cd "${DOWNLOAD_FOLDER}" && stat -qf%z "${CDN_PKG_NAME}")
	if [[ "${LOCAL_PKG_SIZE}" == "${CDN_PKG_SIZE}" ]]; then
		echo "Office-Reset: Downloaded package is wholesome"
	else
		echo "Office-Reset: Downloaded package is malformed. Local file size: ${LOCAL_PKG_SIZE}"
		echo "Office-Reset: Please manually download and install ${APP_NAME} from ${CDN_PKG_URL}"
		exit 1
	fi

	LOCAL_PKG_SIGNING=$(/usr/sbin/pkgutil --check-signature "${DOWNLOAD_FOLDER}${CDN_PKG_NAME}" | awk '/Developer ID Installer'/ | cut -d ':' -f 2 | awk '{$1=$1};1')
	if [[ "${LOCAL_PKG_SIGNING}" == "Microsoft Corporation (UBF8T346G9)" ]]; then
		echo "Office-Reset: Downloaded package is signed by Microsoft"
	else
		echo "Office-Reset: Downloaded package is not signed by Microsoft"
		echo "Office-Reset: Please manually download and install ${APP_NAME} from ${CDN_PKG_URL}"
		exit 1
	fi

	echo "Office-Reset: Starting package install"
	/usr/sbin/installer -pkg "${DOWNLOAD_FOLDER}${CDN_PKG_NAME}" -target /
	if [ $? -eq 0 ]; then
		echo "Office-Reset: Package installed successfully"
	else
		echo "Office-Reset: Package installation failed"
		echo "Office-Reset: Please manually download and install ${APP_NAME} from ${CDN_PKG_URL}"
		exit 1
	fi
}

## Main
LoggedInUser=$(GetLoggedInUser)
SetHomeFolder "$LoggedInUser"
echo "Office-Reset: Running as: $LoggedInUser; Home Folder: $HOME; Mode: $MODE"

echo "Office-Reset: Stopping update services"
/usr/bin/pkill -9 'Microsoft AutoUpdate'
/usr/bin/pkill -9 'Microsoft Update Assistant'
/usr/bin/pkill -9 'Microsoft AU Daemon'
/usr/bin/pkill -9 'Microsoft AU Bootstrapper'
/usr/bin/pkill -9 'com.microsoft.autoupdate.helper'
/usr/bin/pkill -9 'com.microsoft.autoupdate.helpertool'
/usr/bin/pkill -9 'com.microsoft.autoupdate.bootstrapper.helper'

bootoutJob gui "/Library/LaunchAgents/com.microsoft.update.agent.plist"
bootoutJob gui "/Library/LaunchAgents/com.microsoft.autoupdate.helper.plist"
bootoutJob system "/Library/LaunchDaemons/com.microsoft.autoupdate.helper"
bootoutJob system "/Library/LaunchDaemons/com.microsoft.autoupdate.helper.plist"

echo "Office-Reset: Removing configuration data for ${APP_NAME}"
removeFileList \
	"$HOME/Library/Preferences/com.microsoft.autoupdate2.plist" \
	"$HOME/Library/Preferences/com.microsoft.autoupdate.fba.plist" \
	"/Library/Preferences/com.microsoft.autoupdate2.plist" \
	"/Library/Preferences/com.microsoft.autoupdate.fba.plist" \
	"/var/root/Library/Preferences/com.microsoft.autoupdate2.plist" \
	"/var/root/Library/Preferences/com.microsoft.autoupdate.fba.plist" \
	"$TMPDIR/TelemetryUploadFilecom.microsoft.autoupdate.fba.txt" \
	"$TMPDIR/TelemetryUploadFilecom.microsoft.autoupdate2.txt"

removePathList \
	"$HOME/Library/Caches/com.microsoft.autoupdate2" \
	"$HOME/Library/Caches/com.microsoft.autoupdate.fba" \
	"$HOME/Library/HTTPStorages/com.microsoft.autoupdate2" \
	"$HOME/Library/HTTPStorages/com.microsoft.autoupdate.fba" \
	"$HOME/Library/Application Support/Microsoft AU Daemon" \
	"/Library/Application Support/Microsoft/MERP2.0" \
	"$TMPDIR/MSauClones" \
	"/Library/Caches/com.microsoft.autoupdate.helper/" \
	"/Library/Caches/com.microsoft.autoupdate.fba/" \
	"/Applications/.Microsoft Word.app.installBackup" \
	"/Applications/.Microsoft Excel.app.installBackup" \
	"/Applications/.Microsoft PowerPoint.app.installBackup" \
	"/Applications/.Microsoft Outlook.app.installBackup" \
	"/Applications/.Microsoft OneNote.app.installBackup"

/usr/bin/defaults write /Library/Preferences/com.microsoft.autoupdate2 AcknowledgedDataCollectionPolicy -string 'RequiredDataOnly'

if [ -d "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app" ]; then
	APP_VERSION=$(defaults read /Library/Application\ Support/Microsoft/MAU2.0/Microsoft\ AutoUpdate.app/Contents/Info.plist CFBundleVersion)
	echo "Office-Reset: Found version ${APP_VERSION} of ${APP_NAME}"
	if ! is-at-least ${MAU_RECOMMENDED_VERSION} $APP_VERSION; then
		if shouldReinstall; then
			echo "Office-Reset: The installed version of ${APP_NAME} is older than the recommended version ${MAU_RECOMMENDED_VERSION}. Reinstall mode enabled, updating it now"
			RepairApp
		else
			echo "Office-Reset: The installed version of ${APP_NAME} is older than the recommended version ${MAU_RECOMMENDED_VERSION}. Reset mode will not reinstall automatically"
		fi
	fi
	echo "Office-Reset: Checking the app bundle for corruption"
	/usr/bin/codesign -vv --deep /Library/Application\ Support/Microsoft/MAU2.0/Microsoft\ AutoUpdate.app
	if [ $? -gt 0 ]; then
		if shouldReinstall; then
			echo "Office-Reset: The ${APP_NAME} app bundle is damaged and will be removed and reinstalled"
			removePathList "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app"
			RepairApp
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
registerMauApp "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app" "MSau04" "com.microsoft.office"
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
registerMauApp "/Applications/Skype For Business.app" "MSFB16"
registerMauApp "/Applications/Company Portal.app" "IMCP01"
registerMauApp "/Applications/Microsoft Defender.app" "WDAV00"
registerMauApp "/Applications/Microsoft Defender ATP.app" "WDAV00"

exit 0
