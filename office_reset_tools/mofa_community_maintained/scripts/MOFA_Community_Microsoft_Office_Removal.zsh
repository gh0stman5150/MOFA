#!/bin/zsh --no-rcs

# ============================================================
# Script Name: MOFA_Community_Microsoft_Office_Removal.zsh
# Repository: https://github.com/cocopuff2u/MOFA/tree/main/office_reset_tools/mofa_community_maintained
# Description: Removals the Microsoft Office suite for specific applications
#
# Version History:
# 1.0.0 - Based on the latest available package from *Office-Reset.com*; recreated for MOFA to continue maintenance where *Office-Reset.com* left off.
#
# ============================================================


export PATH=/usr/bin:/bin:/usr/sbin:/sbin

echo "Office-Reset: Starting preinstall for Remove_Office"
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

forgetReceiptList() {
	local receipt
	for receipt in "$@"; do
		if /usr/sbin/pkgutil --pkgs | /usr/bin/grep -qxF "$receipt"; then
			echo "Office-Reset: Forgetting package receipt $receipt"
			/usr/sbin/pkgutil --forget "$receipt" >/dev/null 2>&1 || true
		else
			echo "Office-Reset: Skipping missing package receipt $receipt"
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

## Main
LoggedInUser=$(GetLoggedInUser)
SetHomeFolder "$LoggedInUser"
echo "Office-Reset: Running as: $LoggedInUser; Home Folder: $HOME"

echo "Office-Reset: Stopping services"
/usr/bin/pkill -9 'Microsoft Word'
/usr/bin/pkill -9 'Microsoft Excel'
/usr/bin/pkill -9 'Microsoft PowerPoint'
/usr/bin/pkill -9 'Microsoft Outlook'
/usr/bin/pkill -9 'Microsoft OneNote'
/usr/bin/pkill -9 'OneDrive'
/usr/bin/pkill -9 'OneDrive Finder Integration'
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

bootoutJob gui "/Library/LaunchAgents/com.microsoft.update.agent.plist"
bootoutJob gui "/Library/LaunchAgents/com.microsoft.autoupdate.helper.plist"
bootoutJob gui "/Library/LaunchAgents/com.microsoft.OneDriveStandaloneUpdater.plist"
bootoutJob system "/Library/LaunchDaemons/com.microsoft.autoupdate.helper"
bootoutJob system "/Library/LaunchDaemons/com.microsoft.autoupdate.helper.plist"
bootoutJob system "/Library/LaunchDaemons/com.microsoft.OneDriveUpdaterDaemon.plist"
bootoutJob system "/Library/LaunchDaemons/com.microsoft.teams.TeamsUpdaterDaemon.plist"

echo "Office-Reset: Removing apps"
removePathList \
	"/Applications/Microsoft Word.app" \
	"/Applications/Microsoft Excel.app" \
	"/Applications/Microsoft PowerPoint.app" \
	"/Applications/Microsoft Outlook.app" \
	"/Applications/Microsoft OneNote.app" \
	"/Applications/OneDrive.app" \
	"/Applications/Microsoft Teams.app"

echo "Office-Reset: Removing app data"
removePathList \
	"/Library/Application Support/Microsoft/MAU2.0" \
	"/Library/Application Support/Microsoft/MERP2.0" \
	"/Library/Application Support/Microsoft/Office365" \
	"$HOME/Library/Application Support/Microsoft" \
	"$HOME/Library/Application Scripts/com.microsoft.errorreporting" \
	"/Library/Logs/Microsoft"

removeFileList \
	"/Library/LaunchAgents/com.microsoft.update.agent.plist" \
	"/Library/LaunchAgents/com.microsoft.OneDriveStandaloneUpdater.plist" \
	"/Library/LaunchDaemons/com.microsoft.autoupdate.helper.plist" \
	"/Library/LaunchDaemons/com.microsoft.office.licensingV2.helper.plist" \
	"/Library/LaunchDaemons/com.microsoft.OneDriveStandaloneUpdaterDaemon.plist" \
	"/Library/LaunchDaemons/com.microsoft.OneDriveUpdaterDaemon.plist" \
	"/Library/LaunchDaemons/com.microsoft.teams.TeamsUpdaterDaemon.plist" \
	"/Library/PrivilegedHelperTools/com.microsoft.autoupdate.helper" \
	"/Library/PrivilegedHelperTools/com.microsoft.autoupdate.helpertool" \
	"/Library/PrivilegedHelperTools/com.microsoft.office.licensingV2.helper"

# OneDriveFolder=$(/bin/ls "$HOME" | grep 'OneDrive' --max-count=1)
# if [ "$OneDriveFolder" != "" ]; then
#	IsOneDrive=$(/usr/bin/xattr "$HOME/$OneDriveFolder" | grep 'com.apple.fileutil.SyncRootProviderRootContextList')
#	if [ "$IsOneDrive" = "com.apple.fileutil.SyncRootProviderRootContextList" ]; then
#		echo "Office-Reset: Removing OneDrive folder $OneDriveFolder"
#		/bin/rm -rf "$HOME/$OneDriveFolder"
#	fi
# fi

removeFileList \
	"$HOME/Library/Preferences/com.microsoft.autoupdate2.plist" \
	"$HOME/Library/Preferences/com.microsoft.autoupdate.fba.plist" \
	"$HOME/Library/Preferences/com.microsoft.shared.plist" \
	"$HOME/Library/Preferences/com.microsoft.office.plist" \
	"$HOME/Library/Preferences/com.microsoft.Word.plist" \
	"$HOME/Library/Preferences/com.microsoft.Excel.plist" \
	"$HOME/Library/Preferences/com.microsoft.Powerpoint.plist" \
	"$HOME/Library/Preferences/com.microsoft.Outlook.plist" \
	"$HOME/Library/Preferences/com.microsoft.onenote.mac.plist" \
	"$HOME/Library/Preferences/com.microsoft.OneDrive-mac.plist" \
	"$HOME/Library/Preferences/com.microsoft.OneDrive.plist" \
	"$HOME/Library/Preferences/com.microsoft.teams.plist" \
	"/Library/Preferences/com.microsoft.autoupdate2.plist" \
	"/Library/Preferences/com.microsoft.autoupdate.fba.plist" \
	"/Library/Preferences/com.microsoft.shared.plist" \
	"/Library/Preferences/com.microsoft.office.plist" \
	"/Library/Preferences/com.microsoft.Word.plist" \
	"/Library/Preferences/com.microsoft.Excel.plist" \
	"/Library/Preferences/com.microsoft.Powerpoint.plist" \
	"/Library/Preferences/com.microsoft.Outlook.plist" \
	"/Library/Preferences/com.microsoft.onenote.mac.plist" \
	"/Library/Preferences/com.microsoft.OneDrive-mac.plist" \
	"/Library/Preferences/com.microsoft.OneDrive.plist" \
	"/Library/Preferences/com.microsoft.teams.plist" \
	"/Library/Managed Preferences/com.microsoft.shared.plist" \
	"/Library/Managed Preferences/com.microsoft.office.plist" \
	"/Library/Managed Preferences/com.microsoft.Word.plist" \
	"/Library/Managed Preferences/com.microsoft.Excel.plist" \
	"/Library/Managed Preferences/com.microsoft.Powerpoint.plist" \
	"/Library/Managed Preferences/com.microsoft.Outlook.plist" \
	"/Library/Managed Preferences/com.microsoft.onenote.mac.plist" \
	"/Library/Managed Preferences/com.microsoft.OneDrive-mac.plist" \
	"/Library/Managed Preferences/com.microsoft.OneDrive.plist" \
	"/Library/Managed Preferences/com.microsoft.teams.plist" \
	"/var/root/Library/Preferences/com.microsoft.autoupdate2.plist" \
	"/var/root/Library/Preferences/com.microsoft.autoupdate.fba.plist"

removePathList \
	"$HOME/Library/Caches/com.microsoft.autoupdate2" \
	"$HOME/Library/Caches/com.microsoft.autoupdate.fba" \
	"$HOME/Library/Caches/Microsoft" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office" \
	"$HOME/Library/Group Containers/UBF8T346G9.ms" \
	"$HOME/Library/Group Containers/UBF8T346G9.OfficeOsfWebHost" \
	"$HOME/Library/Group Containers/group.com.microsoft"

echo "Office-Reset: Running as: $LoggedInUser; Home Folder: $HOME"

echo "Office-Reset: Removing package receipts"
forgetReceiptList \
	com.microsoft.Word \
	com.microsoft.Excel \
	com.microsoft.Powerpoint \
	com.microsoft.Outlook \
	com.microsoft.onenote.mac \
	com.microsoft.OneDrive-mac \
	com.microsoft.package.Microsoft_Word.app \
	com.microsoft.package.Microsoft_Excel.app \
	com.microsoft.package.Microsoft_PowerPoint.app \
	com.microsoft.package.Microsoft_Outlook.app \
	com.microsoft.package.Microsoft_OneNote.app \
	com.microsoft.package.Microsoft_AutoUpdate.app \
	com.microsoft.package.Microsoft_AU_Bootstrapper.app \
	com.microsoft.package.Proofing_Tools \
	com.microsoft.package.Fonts \
	com.microsoft.package.DFonts \
	com.microsoft.package.Frameworks \
	com.microsoft.pkg.licensing \
	com.microsoft.pkg.licensing.volume \
	com.microsoft.teams \
	com.microsoft.OneDrive

removeFileList \
	"/Library/Preferences/com.microsoft.office.licensingV2.backup" \
	"/Library/Preferences/com.microsoft.autoupdate2.plist" \
	"$HOME/Library/Cookies/com.microsoft.OneDrive.binarycookies" \
	"$HOME/Library/Cookies/com.microsoft.OneDriveUpdater.binarycookies" \
	"$HOME/Library/Cookies/com.microsoft.OneDriveStandaloneUpdater.binarycookies" \
	"$HOME/Library/Cookies/com.microsoft.teams.binarycookies"

removePathList "/Users/Shared/OnDemandInstaller"

exit 0
