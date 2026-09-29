#!/bin/zsh --no-rcs

# ============================================================
# Script Name: MOFA_Community_Microsoft_Outlook_Data_Removal.zsh
# Repository: https://github.com/cocopuff2u/MOFA/tree/main/office_reset_tools/mofa_community_maintained
# Description: Removes the Microsoft Outlook Data
#
# Version History:
# 1.0.0 - Based on the latest available package from *Office-Reset.com*; recreated for MOFA to continue maintenance where *Office-Reset.com* left off.
# 1.1.0 - MOFA refresh: require a console user with a home under /Users, guard removal targets,
#         and return nonzero when a removal fails. Removed unused helpers.
#
# WARNING: permanently deletes the console user's local Outlook data store
# (~/Library/Group Containers/UBF8T346G9.Office/Outlook), including "On My Computer" mail.
# ============================================================

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

echo "Office-Reset: Starting postinstall for Remove_Outlook_Data"

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
if [[ -z "$LoggedInUser" ]]; then
	echo "Office-Reset: No eligible console user with a home under /Users; skipping Outlook data removal"
	exit 0
fi
echo "Office-Reset: Running as: $LoggedInUser; Home Folder: $HOME"

/usr/bin/pkill -9 'Microsoft Outlook'

removeFileList \
	"$HOME/Library/Preferences/com.microsoft.Outlook.plist" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/OutlookProfile.plist"

removePathList "$HOME/Library/Group Containers/UBF8T346G9.Office/Outlook"

FinishRun
