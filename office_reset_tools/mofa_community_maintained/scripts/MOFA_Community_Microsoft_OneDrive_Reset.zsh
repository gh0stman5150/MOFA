#!/bin/zsh --no-rcs

# ============================================================
# Script Name: MOFA_Community_Microsoft_OneDrive_Reset.zsh
# Repository: https://github.com/cocopuff2u/MOFA/tree/main/office_reset_tools/mofa_community_maintained
# Description: Resets the Microsoft OneDrive
#
# Version History:
# 1.0.0 - Based on the latest available package from *Office-Reset.com*; recreated for MOFA to continue maintenance where *Office-Reset.com* left off.
#
# ============================================================


export PATH=/usr/bin:/bin:/usr/sbin:/sbin

echo "Office-Reset: Starting postinstall for Reset_OneDrive"
autoload is-at-least

if [[ $EUID -ne 0 ]]; then
	echo "Office-Reset: This script must be run as root." >&2
	exit 1
fi

APP_NAME="Microsoft OneDrive"
DOWNLOAD_URL="https://go.microsoft.com/fwlink/?linkid=861011"
OS_VERSION=$(sw_vers -productVersion)
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

removePathList() {
	local target
	for target in "$@"; do
		if [[ "$target" != /* || "$target" == "/" ]]; then
			echo "Office-Reset: Refusing unsafe removal target: ${target:-<empty>}" >&2
			return 1
		fi
		/bin/rm -rf -- "$target"
	done
}

removeFileList() {
	local target
	for target in "$@"; do
		if [[ "$target" != /* || "$target" == "/" ]]; then
			echo "Office-Reset: Refusing unsafe removal target: ${target:-<empty>}" >&2
			return 1
		fi
		/bin/rm -f -- "$target"
	done
}

shouldReinstall() {
	[[ "$MODE" == "reinstall" || "$MODE" == "repair" || "$MODE" == "force" ]]
}

RepairApp() {
	DOWNLOAD_FOLDER="/Users/Shared/OnDemandInstaller/"
	if [ -d "$DOWNLOAD_FOLDER" ]; then
		rm -rf "$DOWNLOAD_FOLDER"
	fi
	mkdir -p "$DOWNLOAD_FOLDER"

	CDN_PKG_URL=$(/usr/bin/nscurl --location --head $DOWNLOAD_URL --dump-header - | awk '/Location/' | cut -d ' ' -f2 | tail -1 | awk '{$1=$1};1')
	echo "Office-Reset: Package to download is ${CDN_PKG_URL}"
	CDN_PKG_NAME=$(/usr/bin/basename "${CDN_PKG_URL}")

	CDN_PKG_SIZE=$(/usr/bin/nscurl --location --head $DOWNLOAD_URL --dump-header - | awk '/Content-Length/' | cut -d ' ' -f2 | tail -1 | awk '{$1=$1};1')
	CDN_PKG_MB=$(/bin/expr ${CDN_PKG_SIZE} / 1000 / 1000)
	echo "Office-Reset: Download package is ${CDN_PKG_MB} megabytes in size"

	echo "Office-Reset: Starting ${APP_NAME} package download"
	if ! /usr/bin/nscurl --background --download --large-download --location --download-directory "$DOWNLOAD_FOLDER" "$DOWNLOAD_URL"; then
		echo "Office-Reset: Package download failed" >&2
		exit 1
	fi
	echo "Office-Reset: Finished package download"

	LOCAL_PKG_SIZE=$(cd "${DOWNLOAD_FOLDER}" && stat -qf%z "${CDN_PKG_NAME}")
	if [[ "${LOCAL_PKG_SIZE}" == "${CDN_PKG_SIZE}" ]]; then
		echo "Office-Reset: Downloaded package is wholesome"
	else
		echo "Office-Reset: Downloaded package is malformed. Local file size: ${LOCAL_PKG_SIZE}"
		echo "Office-Reset: Please manually download and install ${APP_NAME} from ${CDN_PKG_URL}"
		exit 1
	fi

	LOCAL_PKG_SIGNING=$(/usr/sbin/pkgutil --check-signature "${DOWNLOAD_FOLDER}${CDN_PKG_NAME}" | awk '/Developer ID Installer'/ | cut -d ':' -f 2 | awk '{$1=$1};1')
	if [[ "${LOCAL_PKG_SIGNING}" == "Microsoft Corporation (UBF8T346G9)" ]]; then
		echo "Office-Reset: Downloaded package is signed by Microsoft"
	else
		echo "Office-Reset: Downloaded package is not signed by Microsoft"
		echo "Office-Reset: Please manually download and install ${APP_NAME} from ${CDN_PKG_URL}"
		exit 1
	fi

	echo "Office-Reset: Starting package install"
	/usr/sbin/installer -pkg "${DOWNLOAD_FOLDER}${CDN_PKG_NAME}" -target /
	if [ $? -eq 0 ]; then
		echo "Office-Reset: Package installed successfully"
	else
		echo "Office-Reset: Package installation failed"
		echo "Office-Reset: Please manually download and install ${APP_NAME} from ${CDN_PKG_URL}"
		exit 1
	fi

}

## Main
LoggedInUser=$(GetLoggedInUser)
SetHomeFolder "$LoggedInUser"
echo "Office-Reset: Running as: $LoggedInUser; Home Folder: $HOME; Mode: $MODE"

/usr/bin/pkill -9 'OneDrive'
/usr/bin/pkill -9 'FinderSync'
/usr/bin/pkill -9 'OneDriveStandaloneUpdater'
/usr/bin/pkill -9 'OneDriveUpdater'

if [ -d "/Applications/OneDrive.app" ]; then
	APP_VERSION=$(defaults read /Applications/OneDrive.app/Contents/Info.plist CFBundleVersion)
	echo "Office-Reset: Found version ${APP_VERSION} of ${APP_NAME}"
	if ! is-at-least 23154.0 $APP_VERSION && is-at-least 10.15 $OS_VERSION; then
		if shouldReinstall; then
			echo "Office-Reset: The installed version of ${APP_NAME} is ancient. Reinstall mode enabled, updating it now"
			RepairApp
		else
			echo "Office-Reset: The installed version of ${APP_NAME} is ancient. Reset mode will not reinstall automatically"
		fi
	fi
	echo "Office-Reset: Checking the app bundle for corruption"
	/usr/bin/codesign -vv --deep /Applications/OneDrive.app
	if [ $? -gt 0 ]; then
		if shouldReinstall; then
			echo "Office-Reset: The ${APP_NAME} app bundle is damaged and will be removed and reinstalled"
			/bin/rm -rf /Applications/OneDrive.app
			RepairApp
		else
			echo "Office-Reset: The ${APP_NAME} app bundle is damaged. Reset mode will not reinstall automatically"
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
removePathList \
	"$HOME/Library/Caches/OneDrive" \
	"$HOME/Library/Caches/com.microsoft.OneDrive" \
	"$HOME/Library/Caches/com.microsoft.OneDriveUpdater" \
	"$HOME/Library/Caches/com.microsoft.OneDriveStandaloneUpdater" \
	"$HOME/Library/Caches/com.microsoft.SyncReporter" \
	"$HOME/Library/Caches/com.microsoft.SharePoint-mac" \
	"$HOME/Library/HTTPStorages/com.microsoft.OneDrive" \
	"$HOME/Library/HTTPStorages/com.microsoft.OneDriveUpdater" \
	"$HOME/Library/HTTPStorages/com.microsoft.SharePoint-mac" \
	"$HOME/Library/HTTPStorages/com.microsoft.SyncReporter" \
	"$HOME/Library/HTTPStorages/com.microsoft.OneDriveStandaloneUpdater" \
	"$HOME/Library/WebKit/com.microsoft.OneDrive" \
	"$HOME/Library/Containers/com.microsoft.OneDrive-mac" \
	"$HOME/Library/Containers/com.microsoft.OneDrive.FinderSync" \
	"$HOME/Library/Containers/com.microsoft.OneDrive-mac.FinderSync" \
	"$HOME/Library/Containers/com.microsoft.OneDriveLauncher" \
	"$HOME/Library/Containers/com.microsoft.OneDrive.FileProvider" \
	"$HOME/Library/Logs/OneDrive" \
	"/Library/Logs/Microsoft/OneDrive" \
	"$HOME/Library/Application Support/OneDrive" \
	"$HOME/Library/Application Support/com.microsoft.OneDrive" \
	"$HOME/Library/Application Support/com.microsoft.OneDriveUpdater" \
	"$HOME/Library/Application Support/com.microsoft.OneDriveStandaloneUpdater" \
	"$HOME/Library/Application Support/com.microsoft.SharePoint-mac" \
	"$HOME/Library/Application Support/OneDriveUpdater" \
	"$HOME/Library/Application Support/OneDriveStandaloneUpdater" \
	"$HOME/Library/Application Scripts/com.microsoft.OneDrive.FinderSync" \
	"$HOME/Library/Application Scripts/com.microsoft.OneDrive.FileProvider" \
	"$HOME/Library/Application Scripts/UBF8T346G9.OneDriveStandaloneSuite" \
	"$HOME/Library/Application Scripts/UBF8T346G9.OfficeOneDriveSyncIntegration" \
	"$HOME/Library/Application Scripts/UBF8T346G9.OneDriveSyncClientSuite" \
	"$HOME/Library/Application Scripts/UBF8T346G9.Kfm" \
	"$HOME/Library/Group Containers/UBF8T346G9.OfficeOneDriveSyncIntegration" \
	"$HOME/Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite" \
	"$HOME/Library/Group Containers/UBF8T346G9.OneDriveSyncClientSuite" \
	"$HOME/Library/Group Containers/UBF8T346G9.Kfm" \
	"${TMPDIR:-/private/tmp}/com.microsoft.OneDrive" \
	"${TMPDIR:-/private/tmp}/com.microsoft.OneDrive.FinderSync"

removeFileList \
	"$HOME/Library/Cookies/com.microsoft.OneDrive.binarycookies" \
	"$HOME/Library/Cookies/com.microsoft.OneDriveUpdater.binarycookies" \
	"$HOME/Library/Cookies/com.microsoft.OneDriveStandaloneUpdater.binarycookies" \
	"$HOME/Library/HTTPStorages/com.microsoft.OneDrive.binarycookies" \
	"$HOME/Library/HTTPStorages/com.microsoft.OneDriveUpdater.binarycookies" \
	"$HOME/Library/HTTPStorages/com.microsoft.SharePoint-mac.binarycookies" \
	"$HOME/Library/HTTPStorages/com.microsoft.SyncReporter.binarycookies" \
	"$HOME/Library/HTTPStorages/com.microsoft.OneDriveStandaloneUpdater.binarycookies" \
	"$HOME/Library/Preferences/com.microsoft.OneDrive.plist" \
	"$HOME/Library/Preferences/com.microsoft.SharePoint-mac.plist" \
	"$HOME/Library/Preferences/com.microsoft.OneDriveStandaloneUpdater.plist" \
	"$HOME/Library/Preferences/com.microsoft.OneDriveUpdater.plist" \
	"$HOME/Library/Preferences/UBF8T346G9.OneDriveStandaloneSuite.plist" \
	"$HOME/Library/Preferences/UBF8T346G9.OfficeOneDriveSyncIntegration.plist" \
	"/Library/Preferences/com.microsoft.OneDrive.plist" \
	"/Library/Preferences/com.microsoft.OneDriveStandaloneUpdater.plist" \
	"/Library/Preferences/com.microsoft.OneDriveUpdater.plist" \
	"/Library/Managed Preferences/com.microsoft.OneDriveStandaloneUpdater.plist" \
	"/Library/Managed Preferences/com.microsoft.OneDriveUpdater.plist" \
	"${TMPDIR:-/private/tmp}/OneDriveVersion.xml"

if [[ -n "$LoggedInUser" ]]; then
	KeychainHasLogin=$(runAsUser /usr/bin/security list-keychains 2>/dev/null | grep 'login.keychain' || true)
	if [ "$KeychainHasLogin" = "" ]; then
		echo "Office-Reset: Adding user login keychain to list"
		runAsUser /usr/bin/security list-keychains -s "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true
	fi

	echo "Display list-keychains for logged-in user"
	runAsUser /usr/bin/security list-keychains || true

	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.OneDrive.FinderSync.HockeySDK' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.OneDrive.HockeySDK' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.OneDriveUpdater.HockeySDK' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.OneDriveStandaloneUpdater.HockeySDK' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'OneDrive Standalone Cached Credential Business - Business1' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'OneDrive Standalone Cached Credential' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -s 'com.microsoft.onedrive.cookies' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -s 'OneAuthAccount' 2>/dev/null || true
	runAsUser /usr/bin/security delete-generic-password -l 'com.microsoft.adalcache' 2>/dev/null || true
else
	echo "Office-Reset: No logged-in user detected; skipping user keychain cleanup"
fi
removePathList "$HOME/Library/Group Containers/UBF8T346G9.com.microsoft.oneauth"

KEYCHAIN_2_PATH=$(/usr/bin/find "$HOME/Library/Keychains" -name keychain-2.db 2>/dev/null | /usr/bin/head -n 1)
if [[ -n "$KEYCHAIN_2_PATH" ]]; then
	/usr/bin/sqlite3 "$KEYCHAIN_2_PATH" "DELETE FROM genp WHERE agrp='UBF8T346G9.com.microsoft.identity.universalstorage';" >/dev/null 2>&1 || true
fi

exit 0
