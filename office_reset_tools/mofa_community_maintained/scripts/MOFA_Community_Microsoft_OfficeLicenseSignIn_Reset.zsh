#!/bin/zsh --no-rcs

# ============================================================
# Script Name: MOFA_Community_Microsoft_OfficeLicenseSignIn_Reset.zsh
# Repository: https://github.com/cocopuff2u/MOFA/tree/main/office_reset_tools/mofa_community_maintained
# Description: Resets Microsoft Office license activation and sign-in state (keychain items, license
#              files and shared OneAuth data) for the console user. Signs the user out of Office,
#              Teams and OneDrive.
#
# Version History:
# 1.0.0 - Based on the latest available package from *Office-Reset.com*; recreated for MOFA to continue maintenance where *Office-Reset.com* left off.
# 1.1.0 - MOFA refresh: replaces the retired MOFA_Community_Microsoft_License_Reset.zsh (a strict subset
#         of this script), quits new Teams and OneDrive before clearing shared sign-in state, caps the
#         keychain delete loops, appends the login keychain to the search list instead of replacing
#         it, only moves license files that exist, and returns nonzero when a removal fails.
# ============================================================

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

echo "Office-Reset: Starting postinstall for Reset_OfficeLicenseSignIn"

if [[ $EUID -ne 0 ]]; then
	echo "Office-Reset: This script must be run as root." >&2
	exit 1
fi

REMOVAL_FAILURES=0
KEYCHAIN_DELETE_LIMIT=50

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

DeleteAllGenericPasswords() { # $1: -G or -l, $2: value
	local attempts=0

	while runAsUser /usr/bin/security find-generic-password "$1" "$2" >/dev/null 2>&1; do
		if (( attempts >= KEYCHAIN_DELETE_LIMIT )); then
			echo "Office-Reset: Stopped deleting '$2' after ${KEYCHAIN_DELETE_LIMIT} attempts" >&2
			return 1
		fi
		(( attempts++ ))
		runAsUser /usr/bin/security delete-generic-password "$1" "$2" >/dev/null 2>&1 || return 1
	done
}

MoveIfPresent() { # $1: source, $2: destination
	if [[ -e "$1" ]]; then
		echo "Office-Reset: Moving $1 to $2"
		if ! /bin/mv -f -- "$1" "$2"; then
			echo "Office-Reset: Failed to move $1" >&2
			(( REMOVAL_FAILURES++ ))
		fi
	else
		echo "Office-Reset: Skipping missing path $1"
	fi
}

## Main
LoggedInUser=$(GetLoggedInUser)
SetHomeFolder "$LoggedInUser"
echo "Office-Reset: Running as: ${LoggedInUser:-<none>}; Home Folder: $HOME"

echo "Office-Reset: Quitting Microsoft apps that share sign-in state"
/usr/bin/pkill -HUP 'Microsoft Word'
/usr/bin/pkill -HUP 'Microsoft Excel'
/usr/bin/pkill -HUP 'Microsoft PowerPoint'
/usr/bin/pkill -HUP 'Microsoft Outlook'
/usr/bin/pkill -HUP 'Microsoft OneNote'
/usr/bin/pkill -HUP 'MSTeams'
/usr/bin/pkill -HUP 'OneDrive'

if [[ -n "$LoggedInUser" ]]; then
	KeychainSearchList=("${(@f)$(runAsUser /usr/bin/security list-keychains -d user 2>/dev/null | /usr/bin/sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')}")
	if [[ ${KeychainSearchList[(I)*login.keychain*]} -eq 0 ]]; then
		echo "Office-Reset: Adding user login keychain to the existing search list"
		runAsUser /usr/bin/security list-keychains -d user -s "$HOME/Library/Keychains/login.keychain-db" "${(@)KeychainSearchList:#}" >/dev/null 2>&1 || true
	fi

	echo "Office-Reset: Keychain search list for logged-in user:"
	runAsUser /usr/bin/security list-keychains -d user || true

	echo "Office-Reset: Removing keychain entries"
	runAsUser /usr/bin/security delete-generic-password -s 'OneAuthAccount' 2>/dev/null || true

	runAsUser /usr/bin/security delete-internet-password -s 'msoCredentialSchemeADAL' 2>/dev/null || true
	runAsUser /usr/bin/security delete-internet-password -s 'msoCredentialSchemeLiveId' 2>/dev/null || true
	DeleteAllGenericPasswords -G 'MSOpenTech.ADAL.1'
	runAsUser /usr/bin/security delete-generic-password -l 'Microsoft Office Identities Cache 2' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'Microsoft Office Identities Cache 3' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'Microsoft Office Identities Settings 2' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'Microsoft Office Identities Settings 3' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'Microsoft Office Ticket Cache' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'Microsoft Office Ticket Cache 2' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.adalcache' 2>/dev/null || true
	DeleteAllGenericPasswords -G 'Microsoft Office Data'
	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.OutlookCore.Secret' 2>/dev/null || true

	DeleteAllGenericPasswords -l 'com.helpshift.data_com.microsoft.Outlook'
	DeleteAllGenericPasswords -l 'MicrosoftOfficeRMSCredential'
	DeleteAllGenericPasswords -l 'MSProtection.framework.service'

	DeleteAllGenericPasswords -l 'Exchange'

	DeleteAllGenericPasswords -l 'Microsoft Teams Identities Cache'
	runAsUser /usr/bin/security delete-generic-password -l 'Teams Safe Storage' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'Microsoft Teams (work or school) Safe Storage' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'teamsIv' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'teamsKey' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.teams.HockeySDK' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.teams.helper.HockeySDK' 2>/dev/null || true

	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.OneDrive.FinderSync.HockeySDK' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.OneDrive.HockeySDK' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.OneDriveUpdater.HockeySDK' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.OneDriveStandaloneUpdater.HockeySDK' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'OneDrive Standalone Cached Credential Business - Business1' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'OneDrive Standalone Cached Credential' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -s 'com.microsoft.onedrive.cookies' 2>/dev/null || true
else
	echo "Office-Reset: No logged-in user detected; skipping user keychain cleanup"
fi

echo "Office-Reset: Removing credential and license files"
removePathList \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/mip_policy" \
	"$HOME/Library/Group Containers/UBF8T346G9.com.microsoft.oneauth"
removeFileList "$HOME/Library/Group Containers/UBF8T346G9.Office/DRM_Evo.plist"

removeFileList "/Library/Preferences/com.microsoft.office.licensingV2.plist.bak"
MoveIfPresent "/Library/Preferences/com.microsoft.office.licensingV2.plist" "/Library/Preferences/com.microsoft.office.licensingV2.backup"

removeFileList \
	"/Library/Application Support/Microsoft/Office365/com.microsoft.Office365.plist" \
	"/Library/Application Support/Microsoft/Office365/com.microsoft.Office365V2.plist" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/com.microsoft.Office365.plist" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/com.microsoft.e0E2OUQxNUY1LTAxOUQtNDQwNS04QkJELTAxQTI5M0JBOTk4O.plist" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/e0E2OUQxNUY1LTAxOUQtNDQwNS04QkJELTAxQTI5M0JBOTk4O" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/com.microsoft.O4kTOBJ0M5ITQxATLEJkQ40SNwQDNtQUOxATL1YUNxQUO2E0e.plist" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/O4kTOBJ0M5ITQxATLEJkQ40SNwQDNtQUOxATL1YUNxQUO2E0e"
MoveIfPresent "$HOME/Library/Group Containers/UBF8T346G9.Office/com.microsoft.Office365V2.plist" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/com.microsoft.Office365V2.backup"

removePathList \
	"/Library/Microsoft/Office/Licenses" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/Licenses" \
	"$HOME/Library/Containers/com.microsoft.RMS-XPCService" \
	"$HOME/Library/Application Scripts/com.microsoft.Office365ServiceV2" \
	"$HOME/Library/Containers/com.microsoft.Word/Data/Library/Application Support/Microsoft" \
	"$HOME/Library/Containers/com.microsoft.Excel/Data/Library/Application Support/Microsoft" \
	"$HOME/Library/Containers/com.microsoft.Powerpoint/Data/Library/Application Support/Microsoft" \
	"$HOME/Library/Containers/com.microsoft.Outlook/Data/Library/Application Support/Microsoft" \
	"$HOME/Library/Containers/com.microsoft.onenote.mac/Data/Library/Application Support/Microsoft"

removeFileList "$HOME/Library/Preferences/com.microsoft.msa-login-hint.plist"

echo "Office-Reset: Changing preferences"
if [ -e "$HOME/Library/Preferences/com.microsoft.office.plist" ]; then
	runAsUser /usr/bin/defaults delete "$HOME/Library/Preferences/com.microsoft.office" OfficeActivationEmailAddress 2>/dev/null || true
	runAsUser /usr/bin/defaults write "$HOME/Library/Preferences/com.microsoft.office" OfficeAutoSignIn -bool TRUE
	runAsUser /usr/bin/defaults write "$HOME/Library/Preferences/com.microsoft.office" HasUserSeenFREDialog -bool TRUE
	runAsUser /usr/bin/defaults write "$HOME/Library/Preferences/com.microsoft.office" HasUserSeenEnterpriseFREDialog -bool TRUE
fi
if [ -d "$HOME/Library/Containers/com.microsoft.Word/Data/Library/Preferences" ]; then
	runAsUser /usr/bin/defaults write "$HOME/Library/Containers/com.microsoft.Word/Data/Library/Preferences/com.microsoft.Word" kSubUIAppCompletedFirstRunSetup1507 -bool FALSE
fi
if [ -d "$HOME/Library/Containers/com.microsoft.Excel/Data/Library/Preferences" ]; then
	runAsUser /usr/bin/defaults write "$HOME/Library/Containers/com.microsoft.Excel/Data/Library/Preferences/com.microsoft.Excel" kSubUIAppCompletedFirstRunSetup1507 -bool FALSE
fi
if [ -d "$HOME/Library/Containers/com.microsoft.Powerpoint/Data/Library/Preferences" ]; then
	runAsUser /usr/bin/defaults write "$HOME/Library/Containers/com.microsoft.Powerpoint/Data/Library/Preferences/com.microsoft.Powerpoint" kSubUIAppCompletedFirstRunSetup1507 -bool FALSE
fi
if [ -d "$HOME/Library/Containers/com.microsoft.Outlook/Data/Library/Preferences" ]; then
	runAsUser /usr/bin/defaults write "$HOME/Library/Containers/com.microsoft.Outlook/Data/Library/Preferences/com.microsoft.Outlook" kSubUIAppCompletedFirstRunSetup1507 -bool FALSE
fi
if [ -d "$HOME/Library/Containers/com.microsoft.onenote.mac/Data/Library/Preferences" ]; then
	runAsUser /usr/bin/defaults write "$HOME/Library/Containers/com.microsoft.onenote.mac/Data/Library/Preferences/com.microsoft.onenote.mac" kSubUIAppCompletedFirstRunSetup1507 -bool FALSE
fi

KEYCHAIN_2_PATH=$(/usr/bin/find "$HOME/Library/Keychains" -name keychain-2.db 2>/dev/null | /usr/bin/head -n 1)
if [[ -n "$KEYCHAIN_2_PATH" ]]; then
	/usr/bin/sqlite3 "$KEYCHAIN_2_PATH" "DELETE FROM genp WHERE agrp='UBF8T346G9.com.microsoft.identity.universalstorage';" >/dev/null 2>&1 || true
fi

removeFileList \
	"$HOME/Library/Keychains/Microsoft_Entity_Certificates-db" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/MicrosoftRegistrationDB.reg"

runAsUser /usr/bin/killall cfprefsd >/dev/null 2>&1 || true

FinishRun
