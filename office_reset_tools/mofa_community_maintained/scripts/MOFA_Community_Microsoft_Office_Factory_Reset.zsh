#!/bin/zsh --no-rcs

# ============================================================
# Script Name: MOFA_Community_Microsoft_Office_Factory_Reset.zsh
# Repository: https://github.com/cocopuff2u/MOFA/tree/main/office_reset_tools/mofa_community_maintained
# Description: Resets shared Microsoft Office, AutoUpdate, OneDrive and Teams preferences, caches and
#              group containers for the console user.
#
# WARNING: removes ~/Library/Group Containers/UBF8T346G9.Office, which includes Outlook profiles and
# local "On My Computer" mail, Normal.dotm and custom dictionaries.
#
# Version History:
# 1.0.0 - Based on the latest available package from *Office-Reset.com*; recreated for MOFA to continue maintenance where *Office-Reset.com* left off.
# 1.1.0 - MOFA refresh: stop new Teams (MSTeams) and clear its cookies, HTTP storage and system
#         preferences, log and guard every removal, skip user data when no console user has a home
#         under /Users, and return nonzero when a removal fails.
# ============================================================

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

echo "Office-Reset: Starting postinstall for Reset_Factory"

if [[ $EUID -ne 0 ]]; then
	echo "Office-Reset: This script must be run as root." >&2
	exit 1
fi

REMOVAL_FAILURES=0

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

## Main
LoggedInUser=$(GetLoggedInUser)
SetHomeFolder "$LoggedInUser"
echo "Office-Reset: Running as: ${LoggedInUser:-<none>}; Home Folder: $HOME"

echo "Office-Reset: Stopping apps and services"
/usr/bin/pkill -9 'Microsoft Word'
/usr/bin/pkill -9 'Microsoft Excel'
/usr/bin/pkill -9 'Microsoft PowerPoint'
/usr/bin/pkill -9 'Microsoft Outlook'
/usr/bin/pkill -9 'Microsoft OneNote'
/usr/bin/pkill -9 'OneDrive'
/usr/bin/pkill -9 'FinderSync'
/usr/bin/pkill -9 'OneDriveStandaloneUpdater'
/usr/bin/pkill -9 'OneDriveUpdater'
/usr/bin/pkill -9 'MSTeams'
/usr/bin/pkill -9 'Microsoft Teams'
/usr/bin/pkill -9 'Microsoft Teams Helper'
/usr/bin/pkill -9 'Microsoft AutoUpdate'
/usr/bin/pkill -9 'Microsoft Update Assistant'
/usr/bin/pkill -9 'Microsoft AU Daemon'
/usr/bin/pkill -9 'Microsoft AU Bootstrapper'
/usr/bin/pkill -9 -f 'com.microsoft.autoupdate.helper'
/usr/bin/pkill -9 -f 'com.microsoft.autoupdate.bootstrapper.helper'

echo "Office-Reset: Removing preferences and containers"
removePathList \
	"/Library/Logs/Microsoft/autoupdate.log" \
	"/Library/Logs/Microsoft/InstallLogs" \
	"/Library/Logs/Microsoft/Teams" \
	"/Library/Logs/Microsoft/OneDrive"

removeFileList \
	"$HOME/Library/Preferences/com.microsoft.autoupdate2.plist" \
	"$HOME/Library/Preferences/com.microsoft.autoupdate.fba.plist" \
	"$HOME/Library/Preferences/com.microsoft.shared.plist" \
	"$HOME/Library/Preferences/com.microsoft.office.plist" \
	"/Library/Preferences/com.microsoft.autoupdate.fba.plist" \
	"/Library/Preferences/com.microsoft.shared.plist" \
	"/Library/Preferences/com.microsoft.office.plist" \
	"/Library/Preferences/com.microsoft.teams.plist" \
	"/Library/Preferences/com.microsoft.teams2.plist" \
	"/Library/Managed Preferences/com.microsoft.shared.plist" \
	"/Library/Managed Preferences/com.microsoft.office.plist" \
	"/var/root/Library/Preferences/com.microsoft.autoupdate2.plist" \
	"/var/root/Library/Preferences/com.microsoft.autoupdate.fba.plist"

removePathList "$HOME/Library/Application Support/Microsoft"

removePathList \
	"$HOME/Library/Caches/com.microsoft.autoupdate2" \
	"$HOME/Library/Caches/com.microsoft.autoupdate.fba"

removePathList "/Library/Application Support/Microsoft/Office365"

removePathList \
	"$HOME/Library/Group Containers/UBF8T346G9.Office" \
	"$HOME/Library/Group Containers/UBF8T346G9.ms" \
	"$HOME/Library/Group Containers/UBF8T346G9.OfficeOsfWebHost"

removePathList \
	"$HOME/Library/Application Scripts/UBF8T346G9.com.microsoft.oneauth" \
	"$HOME/Library/Application Scripts/UBF8T346G9.Office" \
	"$HOME/Library/Application Scripts/UBF8T346G9.ms" \
	"$HOME/Library/Application Scripts/UBF8T346G9.OfficeOsfWebHost" \
	"$HOME/Library/Application Scripts/UBF8T346G9.OfficeOneDriveSyncIntegration"

removeFileList \
	"$HOME/Library/Cookies/com.microsoft.OneDrive.binarycookies" \
	"$HOME/Library/Cookies/com.microsoft.OneDriveUpdater.binarycookies" \
	"$HOME/Library/Cookies/com.microsoft.OneDriveStandaloneUpdater.binarycookies" \
	"$HOME/Library/Cookies/com.microsoft.teams.binarycookies" \
	"$HOME/Library/Cookies/com.microsoft.teams2.binarycookies"

removePathList \
	"$HOME/Library/HTTPStorages/com.microsoft.autoupdate.fba" \
	"$HOME/Library/HTTPStorages/com.microsoft.autoupdate2" \
	"$HOME/Library/HTTPStorages/com.microsoft.OneDrive" \
	"$HOME/Library/HTTPStorages/com.microsoft.OneDriveStandaloneUpdater" \
	"$HOME/Library/HTTPStorages/com.microsoft.teams" \
	"$HOME/Library/HTTPStorages/com.microsoft.teams2"

removeFileList \
	"$HOME/Library/HTTPStorages/com.microsoft.autoupdate.fba.binarycookies" \
	"$HOME/Library/HTTPStorages/com.microsoft.autoupdate2.binarycookies" \
	"$HOME/Library/HTTPStorages/com.microsoft.OneDrive.binarycookies" \
	"$HOME/Library/HTTPStorages/com.microsoft.OneDriveStandaloneUpdater.binarycookies" \
	"$HOME/Library/HTTPStorages/com.microsoft.teams.binarycookies" \
	"$HOME/Library/HTTPStorages/com.microsoft.teams2.binarycookies"

removePathList \
	"$HOME/Library/Containers/com.microsoft.errorreporting" \
	"$HOME/Library/Containers/com.microsoft.netlib.shipassertprocess" \
	"$HOME/Library/Containers/com.microsoft.Office365ServiceV2" \
	"$HOME/Library/Containers/com.microsoft.RMS-XPCService"

FinishRun
