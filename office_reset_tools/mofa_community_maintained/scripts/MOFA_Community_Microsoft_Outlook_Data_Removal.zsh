#!/bin/zsh

# ============================================================
# Script Name: MOFA_Community_Microsoft_Outlook_Data_Removal.zsh
# Repository: https://github.com/cocopuff2u/MOFA/tree/main/office_reset_tools/mofa_community_maintained
# Description: Removes the Microsoft Outlook Data
#
# Version History:
# 1.0.0 - Based on the latest available package from *Office-Reset.com*; recreated for MOFA to continue maintenance where *Office-Reset.com* left off.
#
# ============================================================


export PATH=/usr/bin:/bin:/usr/sbin:/sbin

echo "Office-Reset: Starting postinstall for Remove_Outlook_Data"
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

## Main
LoggedInUser=$(GetLoggedInUser)
SetHomeFolder "$LoggedInUser"
echo "Office-Reset: Running as: $LoggedInUser; Home Folder: $HOME"

/usr/bin/pkill -9 'Microsoft Outlook'

removeFileList \
	"$HOME/Library/Preferences/com.microsoft.Outlook.plist" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/OutlookProfile.plist"

removePathList "$HOME/Library/Group Containers/UBF8T346G9.Office/Outlook"

exit 0
