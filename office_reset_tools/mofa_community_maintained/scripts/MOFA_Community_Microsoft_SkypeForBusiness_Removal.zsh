#!/bin/zsh

# ============================================================
# Script Name: MOFA_Community_Microsoft_SkypeForBusiness_Removal.zsh
# Repository: https://github.com/cocopuff2u/MOFA/tree/main/office_reset_tools/mofa_community_maintained
# Description: Removes the Microsoft Skype For Business application
#
# Version History:
# 1.0.0 - Based on the latest available package from *Office-Reset.com*; recreated for MOFA to continue maintenance where *Office-Reset.com* left off.
#
# ============================================================

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

echo "Office-Reset: Starting postinstall for Remove_SkypeForBusiness"
autoload is-at-least

if [[ $EUID -ne 0 ]]; then
	echo "Office-Reset: This script must be run as root." >&2
	exit 1
fi

SCRIPT_FOLDER=$(/usr/bin/dirname "$0")

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

## Main
LoggedInUser=$(GetLoggedInUser)
SetHomeFolder "$LoggedInUser"
echo "Office-Reset: Running as: $LoggedInUser; Home Folder: $HOME"

/usr/bin/pkill -9 'Skype for Business'

removePathList \
	"$HOME/Library/Application Scripts/com.microsoft.SkypeForBusiness" \
	"$HOME/Library/Containers/com.microsoft.SkypeForBusiness"

removeFileList \
	"$HOME/Library/Preferences/com.microsoft.OutlookSkypeIntegration.plist" \
	"/Library/Preferences/com.microsoft.SkypeForBusiness.plist" \
	"/Library/Managed Preferences/com.microsoft.SkypeForBusiness.plist" \
	"$HOME/Library/Preferences/com.microsoft.SkypeForBusiness.plist"

if [[ -n "$LoggedInUser" ]]; then
	KeychainHasLogin=$(runAsUser /usr/bin/security list-keychains 2>/dev/null | grep 'login.keychain' || true)
	if [ "$KeychainHasLogin" = "" ]; then
		echo "Office-Reset: Adding user login keychain to list"
		runAsUser /usr/bin/security list-keychains -s "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true
	fi

	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.SkypeForBusiness.HockeySDK' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'Skype for Business' 2>/dev/null || true
else
	echo "Office-Reset: No logged-in user detected; skipping user keychain cleanup"
fi

removePathList "/Applications/Skype for Business.app"

forgetReceiptList \
	com.microsoft.package.Microsoft_AU_Bootstrapper.app \
	com.microsoft.SkypeForBusiness

if [ -x "$SCRIPT_FOLDER/dockutil" ]; then
	runAsUser "$SCRIPT_FOLDER/dockutil" --remove com.microsoft.SkypeForBusiness || true
elif command -v dockutil >/dev/null 2>&1; then
	runAsUser "$(command -v dockutil)" --remove com.microsoft.SkypeForBusiness || true
else
	echo "Office-Reset: dockutil is unavailable; skipping Dock cleanup"
fi

exit 0
