#!/bin/zsh

# ============================================================
# Script Name: MOFA_Community_Microsoft_WebExPT_Removal.zsh
# Repository: https://github.com/cocopuff2u/MOFA/tree/main/office_reset_tools/mofa_community_maintained
# Description: Removes the WebExPT application
#
# Version History:
# 1.0.0 - Based on the latest available package from *Office-Reset.com*; recreated for MOFA to continue maintenance where *Office-Reset.com* left off.
#
# ============================================================

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

echo "Office-Reset: Starting postinstall for Remove_WebExPT"
autoload is-at-least

if [[ $EUID -ne 0 ]]; then
	echo "Office-Reset: This script must be run as root." >&2
	exit 1
fi

APP_NAME="WebEx Productivity Tools"

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

bootoutJob() {
	local plist="$1"

	if [[ ! -e "$plist" ]]; then
		echo "Office-Reset: Skipping missing launchd item $plist"
		return 0
	fi

	if [[ -n "$LoggedInUserID" ]]; then
		/bin/launchctl bootout "gui/${LoggedInUserID}" "$plist" >/dev/null 2>&1 || \
		/bin/launchctl unload "$plist" >/dev/null 2>&1 || true
	else
		echo "Office-Reset: No logged-in user detected; skipping gui launchd item $plist"
	fi
}

## Main
LoggedInUser=$(GetLoggedInUser)
SetHomeFolder "$LoggedInUser"
echo "Office-Reset: Running as: $LoggedInUser; Home Folder: $HOME"

echo "Office-Reset: Running native uninstall routine for ${APP_NAME}"
if [[ -x "/Applications/WebEx Productivity Tools/Uninstall/Contents/MacOS/Uninstall" ]]; then
	"/Applications/WebEx Productivity Tools/Uninstall/Contents/MacOS/Uninstall"
else
	echo "Office-Reset: Native uninstall routine is unavailable"
fi

echo "Office-Reset: Stopping WebEx agent"
bootoutJob "/Library/LaunchAgents/com.webex.pluginagent.plist"

echo "Office-Reset: Removing agent configuration for ${APP_NAME}"
removePathList \
	"$HOME/Library/Application Support/Cisco/Webex Plugin" \
	"$HOME/Library/Application Support/Cisco/Webex Meetings" \
	"$HOME/Library/Caches/com.cisco.webex.pluginservice" \
	"$HOME/Library/Caches/com.cisco.webex.webexmta" \
	"$HOME/Library/Group Containers/group.com.cisco.webex.meetings" \
	"$HOME/Library/Logs/PT" \
	"$HOME/Library/Logs/webexmta"
removeFileList "$HOME/Library/Preferences/com.cisco.webex.pluginservice.plist"

echo "Office-Reset: Removing binaries for ${APP_NAME}"
removePathList \
	"/Library/Application Support/Microsoft/WebExPlugin" \
	"/Library/ScriptingAdditions/WebexScriptAddition.osax" \
	"/Users/Shared/WebExPlugin" \
	"/Applications/WebEx Productivity Tools"

if /usr/sbin/pkgutil --pkgs | /usr/bin/grep -qxF "olp.mac.webex.com"; then
	echo "Office-Reset: Forgetting package receipt olp.mac.webex.com"
	/usr/sbin/pkgutil --forget olp.mac.webex.com >/dev/null 2>&1 || true
else
	echo "Office-Reset: Skipping missing package receipt olp.mac.webex.com"
fi

exit 0
