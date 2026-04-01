#!/bin/zsh

# ============================================================
# Script Name: MOFA_Community_Microsoft_Outlook_Reset.zsh
# Repository: https://github.com/cocopuff2u/MOFA/tree/main/office_reset_tools/mofa_community_maintained
# Description: Resets the Microsoft Outlook
#
# Version History:
# 1.0.0 - Based on the latest available package from *Office-Reset.com*; recreated for MOFA to continue maintenance where *Office-Reset.com* left off.
#
# ============================================================

export PATH=/usr/bin:/bin:/usr/sbin:/sbin

echo "Office-Reset: Starting postinstall for Reset_Outlook"

if [[ $EUID -ne 0 ]]; then
	echo "Office-Reset: This script must be run as root." >&2
	exit 1
fi

APP_NAME="Microsoft Outlook"
DOWNLOAD_URL="https://go.microsoft.com/fwlink/?linkid=525137"
SECURITY_ITEM_NOT_FOUND=44 # `security delete-*` returns exit status 44 ("item not found" / errSecItemNotFound); safe to treat as success on supported macOS versions (see `man security`).
KEYCHAIN_DELETE_FAILURE=0
STRICT_KEYCHAIN_DELETE_FAILURES=${STRICT_KEYCHAIN_DELETE_FAILURES:-0}
MODE="${4:-${MODE:-reset}}"
MODE=${MODE:l}

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

GetPrefValue() { # $1: domain, $2: key
	local value

	value=$(/usr/bin/defaults read "$1" "$2" 2>/dev/null) || value=""
	if [[ -z "$value" ]]; then
		value=$(runAsUser /usr/bin/defaults read "$1" "$2" 2>/dev/null) || true
	fi

	printf '%s\n' "$value"
}

shouldReinstall() {
	[[ "$MODE" == "reinstall" || "$MODE" == "repair" || "$MODE" == "force" ]]
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

GetCustomManifestVersion() {
	CHANNEL_NAME=$(GetPrefValue "com.microsoft.autoupdate2" "ChannelName")
	if [ "${CHANNEL_NAME}" = "Custom" ]; then
    	MANIFEST_SERVER=$(GetPrefValue "com.microsoft.autoupdate2" "ManifestServer")
    	echo "Office-Reset: Found custom ManifestServer ${MANIFEST_SERVER}"
    	FULL_UPDATER=$(/usr/bin/nscurl --location ${MANIFEST_SERVER}/0409OPIM2019.xml | grep -A1 -m1 'FullUpdaterLocation' | grep 'string' | sed -e 's,.*<string>\([^<]*\)</string>.*,\1,g')
    	echo "Office-Reset: Found custom FullUpdaterLocation ${FULL_UPDATER}"
    	if [[ "${FULL_UPDATER}" = "https://"* ]]; then
    		CUSTOM_VERSION=$(/usr/bin/nscurl --location ${MANIFEST_SERVER}/0409OPIM2019-chk.xml | grep -A1 -m1 'Update Version' | grep 'string' | sed -e 's,.*<string>\([^<]*\)</string>.*,\1,g')
    		echo "Office-Reset: Found custom update version ${CUSTOM_VERSION}"
    	fi
    fi
}

RepairApp() {
	DOWNLOAD_FOLDER="/Users/Shared/OnDemandInstaller/"
	if [ -d "$DOWNLOAD_FOLDER" ]; then
		rm -rf "$DOWNLOAD_FOLDER"
	fi
	mkdir -p "$DOWNLOAD_FOLDER"

	GetCustomManifestVersion
	if [[ -z "${CUSTOM_VERSION}" ]]; then
		CDN_PKG_URL=$(/usr/bin/nscurl --location --head $DOWNLOAD_URL --dump-header - | awk '/Location/' | cut -d ' ' -f2 | tail -1 | awk '{$1=$1};1')
	else
		CDN_PKG_URL="${FULL_UPDATER}"
	fi
	
	echo "Office-Reset: Package to download is ${CDN_PKG_URL}"
	CDN_PKG_NAME=$(/usr/bin/basename "${CDN_PKG_URL}")

	CDN_PKG_SIZE=$(/usr/bin/nscurl --location --head $CDN_PKG_URL --dump-header - | awk '/Content-Length/' | cut -d ' ' -f2 | tail -1 | awk '{$1=$1};1')
	CDN_PKG_MB=$(/bin/expr ${CDN_PKG_SIZE} / 1000 / 1000)
	echo "Office-Reset: Download package is ${CDN_PKG_MB} megabytes in size"

	echo "Office-Reset: Starting ${APP_NAME} package download"
	/usr/bin/nscurl --background --download --large-download --location --download-directory $DOWNLOAD_FOLDER $CDN_PKG_URL
	echo "Office-Reset: Finished package download"

	LOCAL_PKG_SIZE=$(cd "${DOWNLOAD_FOLDER}" && stat -qf%z "${CDN_PKG_NAME}")
	if [[ "${LOCAL_PKG_SIZE}" == "${CDN_PKG_SIZE}" ]]; then
		echo "Office-Reset: Downloaded package is wholesome"
	else
		echo "Office-Reset: Downloaded package is malformed. Local file size: ${LOCAL_PKG_SIZE}"
		echo "Office-Reset: Please manually download and install ${APP_NAME} from ${CDN_PKG_URL}"
		exit 0
	fi

	LOCAL_PKG_SIGNING=$(/usr/sbin/pkgutil --check-signature ${DOWNLOAD_FOLDER}${CDN_PKG_NAME} | awk '/Developer ID Installer'/ | cut -d ':' -f 2 | awk '{$1=$1};1')
	if [[ "${LOCAL_PKG_SIGNING}" == "Microsoft Corporation (UBF8T346G9)" ]]; then
		echo "Office-Reset: Downloaded package is signed by Microsoft"
	else
		echo "Office-Reset: Downloaded package is not signed by Microsoft"
		echo "Office-Reset: Please manually download and install ${APP_NAME} from ${CDN_PKG_URL}"
		exit 0
	fi

	echo "Office-Reset: Starting package install"
	/usr/sbin/installer -pkg ${DOWNLOAD_FOLDER}${CDN_PKG_NAME} -target /
	if [ $? -eq 0 ]; then
		echo "Office-Reset: Package installed successfully"
	else
		echo "Office-Reset: Package installation failed"
		echo "Office-Reset: Please manually download and install ${APP_NAME} from ${CDN_PKG_URL}"
		exit 0
	fi
	echo "Office-Reset: Exiting without removing configuration data"
	exit 0
}

FindEntryOpenTech() {
	runAsUser /usr/bin/security find-generic-password -G 'MSOpenTech.ADAL.1' 2> /dev/null 1> /dev/null
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

HandleSecurityDeleteResult() {
	local status="$1"
	local item_kind="$2"
	local item_name="$3"
	local output="$4"

	if [[ "$status" -eq 0 || "$status" -eq "$SECURITY_ITEM_NOT_FOUND" ]]; then
		return 0
	fi

	echo "Office-Reset: Failed to delete ${item_kind} '${item_name}' from the keychain: ${output}" >&2
	return $status
}

RunDeleteCommand() {
	"$@"
	local status=$?
	if [[ $status -ne 0 && $KEYCHAIN_DELETE_FAILURE -eq 0 ]]; then
		KEYCHAIN_DELETE_FAILURE=$status
	fi
	return $status
}

DeleteInternetPasswordIfPresent() {
	local output
	local status
	output=$(runAsUser /usr/bin/security delete-internet-password -s "$1" 2>&1)
	status=$?
	HandleSecurityDeleteResult $status "internet password" "$1" "$output"
}

DeleteGenericPasswordIfPresent() {
	local output
	local status
	output=$(runAsUser /usr/bin/security delete-generic-password -l "$1" 2>&1)
	status=$?
	HandleSecurityDeleteResult $status "generic password label" "$1" "$output"
}

DeleteGenericPasswordByGenericAttributeIfPresent() {
	local output
	local status
	output=$(runAsUser /usr/bin/security delete-generic-password -G "$1" 2>&1)
	status=$?
	HandleSecurityDeleteResult $status "generic password attribute" "$1" "$output"
}

## Main
LoggedInUser=$(GetLoggedInUser)
SetHomeFolder "$LoggedInUser"
echo "Office-Reset: Running as: $LoggedInUser; Home Folder: $HOME; Mode: $MODE"

/usr/bin/pkill -9 'Microsoft Outlook'

if [ -d "/Applications/Microsoft Outlook.app" ]; then
	APP_VERSION=$(defaults read /Applications/Microsoft\ Outlook.app/Contents/Info.plist CFBundleVersion)
	echo "Office-Reset: Found version ${APP_VERSION} of ${APP_NAME}"
	echo "Office-Reset: Office for Mac now uses a unified 16.x codebase; skipping legacy 2016/2019 generation checks"
	GetCustomManifestVersion
	if [[ "${CUSTOM_VERSION}" ]] && [[ "${APP_VERSION}" != "${CUSTOM_VERSION}" ]]; then
		if shouldReinstall; then
			echo "Office-Reset: ${APP_NAME} is ${APP_VERSION} on-disk, but the pinned version has been set to ${CUSTOM_VERSION}. Removing and reinstalling"
			removePathList "/Applications/Microsoft Outlook.app"
			RepairApp
		else
			echo "Office-Reset: ${APP_NAME} does not match the pinned version. Reset mode will not reinstall automatically"
		fi
	fi
	echo "Office-Reset: Checking the app bundle for corruption"
	/usr/bin/codesign -vv --deep /Applications/Microsoft\ Outlook.app
	if [ $? -gt 0 ]; then
		CODESIGN_ERROR=$(/usr/bin/codesign -vv --deep /Applications/Microsoft\ Outlook.app)
		echo "Office-Reset: The ${APP_NAME} app bundle is damaged and reporting error ${CODESIGN_ERROR}"
		if [[ "${CODESIGN_ERROR}" = *"OLE.framework"* ]]; then
			echo "Office-Reset: Only OLE.framework has been modified. Ignoring the repair"
		else
			if shouldReinstall; then
				echo "Office-Reset: The ${APP_NAME} app bundle is damaged and will be removed and reinstalled"
				removePathList "/Applications/Microsoft Outlook.app"
				RepairApp
			else
				echo "Office-Reset: The ${APP_NAME} app bundle is damaged. Reset mode will not reinstall automatically"
			fi
		fi
	else
		echo "Office-Reset: Codesign passed successfully"
	fi
else
	echo "Office-Reset: ${APP_NAME} was not found in the default location"
	if shouldReinstall; then
		echo "Office-Reset: Reinstall mode enabled, installing ${APP_NAME}"
		RepairApp
	fi
fi

echo "Office-Reset: Removing configuration data for ${APP_NAME}"
removeFileList \
	"/Library/Preferences/com.microsoft.Outlook.plist" \
	"/Library/Managed Preferences/com.microsoft.Outlook.plist" \
	"$HOME/Library/Preferences/com.microsoft.Outlook.plist" \
	"/Library/Application Support/Microsoft/Office365/User Content.localized/Startup.localized/Word/NormalEmail.dotm" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Startup.localized/Word/NormalEmail.dotm" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/DRM_Evo.plist"

removePathList \
	"$HOME/Library/Containers/com.microsoft.Outlook" \
	"$HOME/Library/Containers/com.microsoft.Outlook.CalendarWidget" \
	"$HOME/Library/Application Scripts/com.microsoft.Outlook" \
	"$HOME/Library/Application Scripts/com.microsoft.Outlook.CalendarWidget" \
	"/Library/Application Support/Microsoft/WebExPlugin" \
	"/Library/Application Support/Microsoft/ZoomOutlookPlugin" \
	"/Users/Shared/ZoomOutlookPlugin" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/mip_policy" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/FontCache" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/ComRPC32" \
	"$HOME/Library/Group Containers/UBF8T346G9.Office/TemporaryItems"
OfficeAclFiles=($HOME/Library/Group\ Containers/UBF8T346G9.Office/Microsoft\ Office\ ACL*(N))
if (( ${#OfficeAclFiles[@]} )); then
	/bin/rm -f "${OfficeAclFiles[@]}"
fi
	removeFileList "$HOME/Library/Group Containers/UBF8T346G9.Office/MicrosoftRegistrationDB.reg"

	removePathList "$TMPDIR/com.microsoft.Outlook" "/Applications/.Microsoft Outlook.app.installBackup"

if [[ -n "$LoggedInUser" ]]; then
	KeychainHasLogin=$(runAsUser /usr/bin/security list-keychains 2>/dev/null | grep 'login.keychain' || true)
	if [ "$KeychainHasLogin" = "" ]; then
		echo "Office-Reset: Adding user login keychain to list"
		runAsUser /usr/bin/security list-keychains -s "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true
	fi

	echo "Display list-keychains for logged-in user"
	runAsUser /usr/bin/security list-keychains || true

	while [[ $(FindEntryOpenTech) -eq 0 ]]; do
		RunDeleteCommand DeleteGenericPasswordByGenericAttributeIfPresent 'MSOpenTech.ADAL.1' || break
	done
	RunDeleteCommand DeleteInternetPasswordIfPresent 'msoCredentialSchemeADAL'
	RunDeleteCommand DeleteInternetPasswordIfPresent 'msoCredentialSchemeLiveId'
	RunDeleteCommand DeleteGenericPasswordIfPresent 'Microsoft Office Identities Cache 2'
	RunDeleteCommand DeleteGenericPasswordIfPresent 'Microsoft Office Identities Cache 3'
	RunDeleteCommand DeleteGenericPasswordIfPresent 'Microsoft Office Identities Settings 2'
	RunDeleteCommand DeleteGenericPasswordIfPresent 'Microsoft Office Identities Settings 3'
	RunDeleteCommand DeleteGenericPasswordIfPresent 'Microsoft Office Ticket Cache'
	RunDeleteCommand DeleteGenericPasswordIfPresent 'Microsoft Office Ticket Cache 2'
	RunDeleteCommand DeleteGenericPasswordIfPresent 'com.microsoft.adalcache'
	RunDeleteCommand DeleteGenericPasswordIfPresent 'com.microsoft.OutlookCore.Secret'
	while [[ $(FindEntryHelpShift) -eq 0 ]]; do
		RunDeleteCommand DeleteGenericPasswordIfPresent 'com.helpshift.data_com.microsoft.Outlook' || break
	done
	while [[ $(FindEntryRMSCredential) -eq 0 ]]; do
		RunDeleteCommand DeleteGenericPasswordIfPresent 'MicrosoftOfficeRMSCredential' || break
	done
	while [[ $(FindEntryProtectionService) -eq 0 ]]; do
		RunDeleteCommand DeleteGenericPasswordIfPresent 'MSProtection.framework.service' || break
	done

	while [[ $(FindEntryExchange) -eq 0 ]]; do
		RunDeleteCommand DeleteGenericPasswordIfPresent 'Exchange' || break
	done
else
	echo "Office-Reset: No logged-in user detected; skipping user keychain cleanup"
fi

if [[ $KEYCHAIN_DELETE_FAILURE -ne 0 ]]; then
	echo "Office-Reset: Completed with one or more keychain deletion errors" >&2
	if [[ "$STRICT_KEYCHAIN_DELETE_FAILURES" == "1" ]]; then
		exit $KEYCHAIN_DELETE_FAILURE
	fi
fi

exit 0
