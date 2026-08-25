#!/bin/zsh --no-rcs

# ============================================================
# Script Name: MOFA_Community_Microsoft_ZoomPlugin_Removal.zsh
# Repository: https://github.com/cocopuff2u/MOFA/tree/main/office_reset_tools/mofa_community_maintained
# Description: Removes the legacy Zoom Outlook plugin for macOS.
#
# Version History:
# 1.0.0 - Based on the latest available package from *Office-Reset.com*; recreated for MOFA to continue maintenance where *Office-Reset.com* left off.
# 1.0.1 - Rebuilt from an inherited Skype-for-Business template to remove legacy Zoom Outlook plugin remnants and align guidance with Zoom's recommendation to migrate macOS users to the Zoom for Outlook add-in.
#
# ============================================================

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

echo "Office-Reset: Starting postinstall for Remove_ZoomPlugin"
autoload is-at-least

if [[ $EUID -ne 0 ]]; then
	echo "Office-Reset: This script must be run as root." >&2
	exit 1
fi

APP_NAME="Zoom Outlook plugin"

GetLoggedInUser() {
	/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk '/Name :/&&!/loginwindow/{print $3}'
}

SetHomeFolder() {
	local target_user="$1"

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

forgetReceiptsMatching() {
	local pattern="$1"
	local receipt
	local found=0

	while IFS= read -r receipt; do
		[[ -z "$receipt" ]] && continue
		found=1
		echo "Office-Reset: Forgetting package receipt $receipt"
		/usr/sbin/pkgutil --forget "$receipt" >/dev/null 2>&1 || true
	done < <(/usr/sbin/pkgutil --pkgs 2>/dev/null | /usr/bin/grep -Ei "$pattern" || true)

	if [[ $found -eq 0 ]]; then
		echo "Office-Reset: No package receipts matched pattern $pattern"
	fi
}

## Main
LoggedInUser=$(GetLoggedInUser)
SetHomeFolder "$LoggedInUser"
echo "Office-Reset: Running as: $LoggedInUser; Home Folder: $HOME"
echo "Office-Reset: Zoom recommends migrating macOS users from the legacy ${APP_NAME} to the Zoom for Outlook add-in."

/usr/bin/pkill -9 'Microsoft Outlook' >/dev/null 2>&1 || true

echo "Office-Reset: Removing plugin remnants for ${APP_NAME}"
removePathList \
	"/Library/Application Support/Microsoft/ZoomOutlookPlugin" \
	"/Users/Shared/ZoomOutlookPlugin" \
	"$HOME/Documents/ZoomOutlookPlugin" \
	"$HOME/Library/Containers/com.microsoft.outlook/Data/Documents/ZoomOutlookPlugin" \
	"$HOME/Library/Containers/com.microsoft.Outlook/Data/Documents/ZoomOutlookPlugin"

forgetReceiptsMatching 'zoom.*outlook|outlook.*zoom'

exit 0
