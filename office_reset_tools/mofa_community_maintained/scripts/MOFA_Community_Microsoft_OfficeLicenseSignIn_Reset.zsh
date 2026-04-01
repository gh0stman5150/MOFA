#!/bin/zsh

# ============================================================
# Script Name: MOFA_Community_Microsoft_OfficeLicenseSignIn_Reset.zsh
# Repository: https://github.com/cocopuff2u/MOFA/tree/main/office_reset_tools/mofa_community_maintained
# Description: Resets the Microsoft Office License Sign-in for specific applications.
#
# Version History:
# 1.0.0 - Based on the latest available package from *Office-Reset.com*; recreated for MOFA to continue maintenance where *Office-Reset.com* left off.
#
# ============================================================


export PATH=/usr/bin:/bin:/usr/sbin:/sbin

echo "Office-Reset: Starting postinstall for Reset_Credentials"
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

FindEntryOpenTech() {
	runAsUser /usr/bin/security find-generic-password -G 'MSOpenTech.ADAL.1' 2> /dev/null 1> /dev/null
	echo $?
}
FindEntryOfficeData() {
	runAsUser /usr/bin/security find-generic-password -G 'Microsoft Office Data' 2> /dev/null 1> /dev/null
	echo $?
}
FindEntryHelpShift() {
	runAsUser /usr/bin/security find-generic-password -l 'com.helpshift.data_com.microsoft.Outlook' 2> /dev/null 1> /dev/null
	echo $?
}
FindEntryRMSCredential() {
	runAsUser /usr/bin/security find-generic-password -l 'MicrosoftOfficeRMSCredential' 2> /dev/null 1> /dev/null
	echo $?
}
FindEntryProtectionService() {
	runAsUser /usr/bin/security find-generic-password -l 'MSProtection.framework.service' 2> /dev/null 1> /dev/null
	echo $?
}
FindEntryExchange() {
	runAsUser /usr/bin/security find-generic-password -l 'Exchange' 2> /dev/null 1> /dev/null
	echo $?
}
FindEntryTeamsIdentity() {
	runAsUser /usr/bin/security find-generic-password -l 'Microsoft Teams Identities Cache' 2> /dev/null 1> /dev/null
	echo $?
}

## Main
LoggedInUser=$(GetLoggedInUser)
SetHomeFolder "$LoggedInUser"
echo "Office-Reset: Running as: $LoggedInUser; Home Folder: $HOME"

echo "Office-Reset: Quitting all apps gracefully"
/usr/bin/pkill -HUP 'Microsoft Word'
/usr/bin/pkill -HUP 'Microsoft Excel'
/usr/bin/pkill -HUP 'Microsoft PowerPoint'
/usr/bin/pkill -HUP 'Microsoft Outlook'
/usr/bin/pkill -HUP 'Microsoft OneNote'

if [[ -n "$LoggedInUser" ]]; then
	KeychainHasLogin=$(runAsUser /usr/bin/security list-keychains 2>/dev/null | grep 'login.keychain' || true)
	if [ "$KeychainHasLogin" = "" ]; then
		echo "Office-Reset: Adding user login keychain to list"
		runAsUser /usr/bin/security list-keychains -s "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true
	fi

	echo "Display list-keychains for logged-in user"
	runAsUser /usr/bin/security list-keychains || true

	echo "Office-Reset: Removing keychain entries"
	runAsUser /usr/bin/security delete-generic-password -s 'OneAuthAccount' 2>/dev/null || true

	runAsUser /usr/bin/security delete-internet-password -s 'msoCredentialSchemeADAL' 2>/dev/null || true
	runAsUser /usr/bin/security delete-internet-password -s 'msoCredentialSchemeLiveId' 2>/dev/null || true
	while [[ $(FindEntryOpenTech) -eq 0 ]]; do
		runAsUser /usr/bin/security delete-generic-password -G 'MSOpenTech.ADAL.1' 2>/dev/null || break
	done
	runAsUser /usr/bin/security delete-generic-password -l 'Microsoft Office Identities Cache 2' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'Microsoft Office Identities Cache 3' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'Microsoft Office Identities Settings 2' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'Microsoft Office Identities Settings 3' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'Microsoft Office Ticket Cache' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'Microsoft Office Ticket Cache 2' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.adalcache' 2>/dev/null || true
	while [[ $(FindEntryOfficeData) -eq 0 ]]; do
		runAsUser /usr/bin/security delete-generic-password -G 'Microsoft Office Data' 2>/dev/null || break
	done
	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.OutlookCore.Secret' 2>/dev/null || true

	while [[ $(FindEntryHelpShift) -eq 0 ]]; do
		runAsUser /usr/bin/security delete-generic-password -l 'com.helpshift.data_com.microsoft.Outlook' 2>/dev/null || break
	done
	while [[ $(FindEntryRMSCredential) -eq 0 ]]; do
		runAsUser /usr/bin/security delete-generic-password -l 'MicrosoftOfficeRMSCredential' 2>/dev/null || break
	done
	while [[ $(FindEntryProtectionService) -eq 0 ]]; do
		runAsUser /usr/bin/security delete-generic-password -l 'MSProtection.framework.service' 2>/dev/null || break
	done

	while [[ $(FindEntryExchange) -eq 0 ]]; do
		runAsUser /usr/bin/security delete-generic-password -l 'Exchange' 2>/dev/null || break
	done

	while [[ $(FindEntryTeamsIdentity) -eq 0 ]]; do
		runAsUser /usr/bin/security delete-generic-password -l 'Microsoft Teams Identities Cache' 2>/dev/null || break
	done
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
	runAsUser /usr/bin/security delete-generic-password -s 'OneAuthAccount' 2>/dev/null || true
else
	echo "Office-Reset: No logged-in user detected; skipping user keychain cleanup"
fi

echo "Office-Reset: Removing credential and license files"
/bin/rm -rf $HOME/Library/Group\ Containers/UBF8T346G9.Office/mip_policy
/bin/rm -f $HOME/Library/Group\ Containers/UBF8T346G9.Office/DRM_Evo.plist
/bin/rm -rf $HOME/Library/Group\ Containers/UBF8T346G9.com.microsoft.oneauth

/bin/rm -f /Library/Preferences/com.microsoft.office.licensingV2.plist.bak
/bin/mv /Library/Preferences/com.microsoft.office.licensingV2.plist /Library/Preferences/com.microsoft.office.licensingV2.backup

/bin/rm -f /Library/Application\ Support/Microsoft/Office365/com.microsoft.Office365.plist
/bin/rm -f /Library/Application\ Support/Microsoft/Office365/com.microsoft.Office365V2.plist
/bin/rm -f $HOME/Library/Group\ Containers/UBF8T346G9.Office/com.microsoft.Office365.plist
/bin/mv $HOME/Library/Group\ Containers/UBF8T346G9.Office/com.microsoft.Office365V2.plist $HOME/Library/Group\ Containers/UBF8T346G9.Office/com.microsoft.Office365V2.backup
/bin/rm -f $HOME/Library/Group\ Containers/UBF8T346G9.Office/com.microsoft.e0E2OUQxNUY1LTAxOUQtNDQwNS04QkJELTAxQTI5M0JBOTk4O.plist
/bin/rm -f $HOME/Library/Group\ Containers/UBF8T346G9.Office/e0E2OUQxNUY1LTAxOUQtNDQwNS04QkJELTAxQTI5M0JBOTk4O
/bin/rm -f $HOME/Library/Group\ Containers/UBF8T346G9.Office/com.microsoft.O4kTOBJ0M5ITQxATLEJkQ40SNwQDNtQUOxATL1YUNxQUO2E0e.plist
/bin/rm -f $HOME/Library/Group\ Containers/UBF8T346G9.Office/O4kTOBJ0M5ITQxATLEJkQ40SNwQDNtQUOxATL1YUNxQUO2E0e

/bin/rm -rf /Library/Microsoft/Office/Licenses
/bin/rm -rf $HOME/Library/Group\ Containers/UBF8T346G9.Office/Licenses
/bin/rm -rf $HOME/Library/Containers/com.microsoft.RMS-XPCService
/bin/rm -rf $HOME/Library/Application\ Scripts/com.microsoft.Office365ServiceV2

/bin/rm -rf $HOME/Library/Containers/com.microsoft.Word/Data/Library/Application\ Support/Microsoft
/bin/rm -rf $HOME/Library/Containers/com.microsoft.Excel/Data/Library/Application\ Support/Microsoft
/bin/rm -rf $HOME/Library/Containers/com.microsoft.Powerpoint/Data/Library/Application\ Support/Microsoft
/bin/rm -rf $HOME/Library/Containers/com.microsoft.Outlook/Data/Library/Application\ Support/Microsoft
/bin/rm -rf $HOME/Library/Containers/com.microsoft.onenote.mac/Data/Library/Application\ Support/Microsoft

/bin/rm -f $HOME/Library/Preferences/com.microsoft.msa-login-hint.plist

echo "Office-Reset: Changing preferences"
if [ -e "$HOME/Library/Preferences/com.microsoft.office.plist" ]; then
	runAsUser /usr/bin/defaults delete $HOME/Library/Preferences/com.microsoft.office OfficeActivationEmailAddress 2>/dev/null || true
	runAsUser /usr/bin/defaults write $HOME/Library/Preferences/com.microsoft.office OfficeAutoSignIn -bool TRUE
	runAsUser /usr/bin/defaults write $HOME/Library/Preferences/com.microsoft.office HasUserSeenFREDialog -bool TRUE
	runAsUser /usr/bin/defaults write $HOME/Library/Preferences/com.microsoft.office HasUserSeenEnterpriseFREDialog -bool TRUE
fi
if [ -d "$HOME/Library/Containers/com.microsoft.Word/Data/Library/Preferences" ]; then
	runAsUser /usr/bin/defaults write $HOME/Library/Containers/com.microsoft.Word/Data/Library/Preferences/com.microsoft.Word kSubUIAppCompletedFirstRunSetup1507 -bool FALSE
fi
if [ -d "$HOME/Library/Containers/com.microsoft.Excel/Data/Library/Preferences" ]; then
	runAsUser /usr/bin/defaults write $HOME/Library/Containers/com.microsoft.Excel/Data/Library/Preferences/com.microsoft.Excel kSubUIAppCompletedFirstRunSetup1507 -bool FALSE
fi
if [ -d "$HOME/Library/Containers/com.microsoft.Powerpoint/Data/Library/Preferences" ]; then
	runAsUser /usr/bin/defaults write $HOME/Library/Containers/com.microsoft.Powerpoint/Data/Library/Preferences/com.microsoft.Powerpoint kSubUIAppCompletedFirstRunSetup1507 -bool FALSE
fi
if [ -d "$HOME/Library/Containers/com.microsoft.Outlook/Data/Library/Preferences" ]; then
	runAsUser /usr/bin/defaults write $HOME/Library/Containers/com.microsoft.Outlook/Data/Library/Preferences/com.microsoft.Outlook kSubUIAppCompletedFirstRunSetup1507 -bool FALSE
fi
if [ -d "$HOME/Library/Containers/com.microsoft.onenote.mac/Data/Library/Preferences" ]; then
	runAsUser /usr/bin/defaults write $HOME/Library/Containers/com.microsoft.onenote.mac/Data/Library/Preferences/com.microsoft.onenote.mac kSubUIAppCompletedFirstRunSetup1507 -bool FALSE
fi

KEYCHAIN_2_PATH=$(/usr/bin/find "$HOME/Library/Keychains" -name keychain-2.db 2>/dev/null | /usr/bin/head -n 1)
if [[ -n "$KEYCHAIN_2_PATH" ]]; then
	/usr/bin/sqlite3 "$KEYCHAIN_2_PATH" "DELETE FROM genp WHERE agrp='UBF8T346G9.com.microsoft.identity.universalstorage';" >/dev/null 2>&1 || true
fi

/bin/rm -f $HOME/Library/Keychains/Microsoft_Entity_Certificates-db
/bin/rm -f $HOME/Library/Group\ Containers/UBF8T346G9.Office/MicrosoftRegistrationDB.reg

runAsUser /usr/bin/killall cfprefsd >/dev/null 2>&1 || true

exit 0
