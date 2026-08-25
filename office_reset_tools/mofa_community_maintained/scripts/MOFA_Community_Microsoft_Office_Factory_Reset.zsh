#!/bin/zsh --no-rcs

# ============================================================
# Script Name: MOFA_Community_Microsoft_Office_Factory_Reset.zsh
# Repository: https://github.com/cocopuff2u/MOFA/tree/main/office_reset_tools/mofa_community_maintained
# Description: Resets the Microsoft Office suite for specific applications
#
# Version History:
# 1.0.0 - Based on the latest available package from *Office-Reset.com*; recreated for MOFA to continue maintenance where *Office-Reset.com* left off.
#
# ============================================================


export PATH=/usr/bin:/bin:/usr/sbin:/sbin

echo "Office-Reset: Starting postinstall for Reset_Factory"
autoload is-at-least

if [[ $EUID -ne 0 ]]; then
	echo "Office-Reset: This script must be run as root." >&2
	exit 1
fi


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

## Main
LoggedInUser=$(GetLoggedInUser)
SetHomeFolder "$LoggedInUser"
echo "Office-Reset: Running as: $LoggedInUser; Home Folder: $HOME"

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
/usr/bin/pkill -9 'Microsoft Teams'
/usr/bin/pkill -9 'Microsoft Teams Helper'
/usr/bin/pkill -9 'Microsoft AutoUpdate'
/usr/bin/pkill -9 'Microsoft Update Assistant'
/usr/bin/pkill -9 'Microsoft AU Daemon'
/usr/bin/pkill -9 'Microsoft AU Bootstrapper'
/usr/bin/pkill -9 'com.microsoft.autoupdate.helper'
/usr/bin/pkill -9 'com.microsoft.autoupdate.helpertool'
/usr/bin/pkill -9 'com.microsoft.autoupdate.bootstrapper.helper'

echo "Office-Reset: Removing preferences and containers"
/bin/rm -rf "/Library/Logs/Microsoft/autoupdate.log"
/bin/rm -rf "/Library/Logs/Microsoft/InstallLogs"
/bin/rm -rf "/Library/Logs/Microsoft/Teams"
/bin/rm -rf "/Library/Logs/Microsoft/OneDrive"

/bin/rm -f "$HOME/Library/Preferences/com.microsoft.autoupdate2.plist"
/bin/rm -f "$HOME/Library/Preferences/com.microsoft.autoupdate.fba.plist"
/bin/rm -f "$HOME/Library/Preferences/com.microsoft.shared.plist"
/bin/rm -f "$HOME/Library/Preferences/com.microsoft.office.plist"
/bin/rm -f "/Library/Preferences/com.microsoft.autoupdate.fba.plist"
/bin/rm -f "/Library/Preferences/com.microsoft.shared.plist"
/bin/rm -f "/Library/Preferences/com.microsoft.office.plist"
/bin/rm -f "/Library/Preferences/com.microsoft.teams.plist"
/bin/rm -f "/Library/Managed Preferences/com.microsoft.shared.plist"
/bin/rm -f "/Library/Managed Preferences/com.microsoft.office.plist"
/bin/rm -f "/var/root/Library/Preferences/com.microsoft.autoupdate2.plist"
/bin/rm -f "/var/root/Library/Preferences/com.microsoft.autoupdate.fba.plist"

/bin/rm -rf "$HOME/Library/Application Support/Microsoft"

/bin/rm -rf "$HOME/Library/Caches/com.microsoft.autoupdate2"
/bin/rm -rf "$HOME/Library/Caches/com.microsoft.autoupdate.fba"

/bin/rm -rf "/Library/Application Support/Microsoft/Office365"

/bin/rm -rf "$HOME/Library/Group Containers/UBF8T346G9.Office"
/bin/rm -rf "$HOME/Library/Group Containers/UBF8T346G9.ms"
/bin/rm -rf "$HOME/Library/Group Containers/UBF8T346G9.OfficeOsfWebHost"

/bin/rm -rf "$HOME/Library/Application Scripts/UBF8T346G9.com.microsoft.oneauth"
/bin/rm -rf "$HOME/Library/Application Scripts/UBF8T346G9.Office"
/bin/rm -rf "$HOME/Library/Application Scripts/UBF8T346G9.ms"
/bin/rm -rf "$HOME/Library/Application Scripts/UBF8T346G9.OfficeOsfWebHost"
/bin/rm -rf "$HOME/Library/Application Scripts/UBF8T346G9.OfficeOneDriveSyncIntegration"

/bin/rm -f "$HOME/Library/Cookies/com.microsoft.OneDrive.binarycookies"
/bin/rm -f "$HOME/Library/Cookies/com.microsoft.OneDriveUpdater.binarycookies"
/bin/rm -f "$HOME/Library/Cookies/com.microsoft.OneDriveStandaloneUpdater.binarycookies"
/bin/rm -f "$HOME/Library/Cookies/com.microsoft.teams.binarycookies"

/bin/rm -rf "$HOME/Library/HTTPStorages/com.microsoft.autoupdate.fba"
/bin/rm -rf "$HOME/Library/HTTPStorages/com.microsoft.autoupdate2"
/bin/rm -rf "$HOME/Library/HTTPStorages/com.microsoft.OneDrive"
/bin/rm -rf "$HOME/Library/HTTPStorages/com.microsoft.OneDriveStandaloneUpdater"
/bin/rm -rf "$HOME/Library/HTTPStorages/com.microsoft.teams"

/bin/rm -f "$HOME/Library/HTTPStorages/com.microsoft.autoupdate.fba.binarycookies"
/bin/rm -f "$HOME/Library/HTTPStorages/com.microsoft.autoupdate2.binarycookies"
/bin/rm -f "$HOME/Library/HTTPStorages/com.microsoft.OneDrive.binarycookies"
/bin/rm -f "$HOME/Library/HTTPStorages/com.microsoft.OneDriveStandaloneUpdater.binarycookies"
/bin/rm -f "$HOME/Library/HTTPStorages/com.microsoft.teams.binarycookies"

/bin/rm -rf "$HOME/Library/Containers/com.microsoft.errorreporting"
/bin/rm -rf "$HOME/Library/Containers/com.microsoft.netlib.shipassertprocess"
/bin/rm -rf "$HOME/Library/Containers/com.microsoft.Office365ServiceV2"
/bin/rm -rf "$HOME/Library/Containers/com.microsoft.RMS-XPCService"

exit 0
